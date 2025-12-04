#!/usr/bin/env ruby

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'

def log(message, level = :debug)
  puts sprintf('[%s] [%5s] %s', Time.now.strftime('%H.%M.%S'), level.to_s.upcase!, message)
  exit(1) if level.eql?(:fatal)
end

class VideoCompiler
  TRANSITION_DURATION = 0.5 # Duration of white fade in seconds
  
  def initialize(map_file, output_file)
    @map_file = map_file
    @output_file = output_file
    # Use a stable temp directory based on the map file name for resumability
    map_basename = File.basename(@map_file, '.*').gsub(/[^\w\-\.]/, '_')
    @temp_dir = File.join(Dir.tmpdir, "video_compile_#{map_basename}")
    FileUtils.mkdir_p(@temp_dir)
    @segment_files = []
  end

  def compile
    if File.exist?(@output_file)
      log(sprintf('output already exists[%s]; skipping compile', @output_file), :info)
      return
    end
    log(sprintf('reading map file[%s]', @map_file), :info)
    map = JSON.parse(File.read(@map_file))
    
    log(sprintf('processing[%d] video files...', map.size))
    
    # Process each segment from the map
    segment_index = 0
    map.each do |video_path, trails|
      trails.each do |trail_name, timestamps|
        start_time, end_time = timestamps

        # TODO we should precompute the segment count so this is more useful
        log(sprintf('  segment %d: [%s] (%s - %s)', segment_index + 1, trail_name, start_time, end_time), :info)
        
        # Create segment with overlay
        segment_file = create_segment(video_path, trail_name, start_time, end_time, segment_index)
        @segment_files << segment_file
        
        # Create transition (except after the last segment)
        # We'll add transitions when concatenating
        
        segment_index += 1
      end
    end
    
    log(sprintf('%s concatenating[%d] segments with transitions', "\n", @segment_files.size))
    concatenate_with_transitions
    
    if ENV['SUPERCUT_CLEAN'] == '1'
      log('cleaning up temporary files', :debug)
      FileUtils.rm_rf(@temp_dir)
    else
      log(sprintf('leaving temporary files in[%s] for resumability', @temp_dir), :debug)
    end
    
    log(sprintf('video compiled successfully[%s]', @output_file))
  end

  private

  def parse_timestamp(timestamp)
    # Convert MM:SS to seconds
    parts = timestamp.split(':').map(&:to_i)
    if parts.size == 2
      parts[0] * 60 + parts[1]
    elsif parts.size == 3
      parts[0] * 3600 + parts[1] * 60 + parts[2]
    else
      raise "Invalid timestamp format: #{timestamp}"
    end
  end

  def create_segment(video_path, trail_name, start_time, end_time, index)
    start_seconds = parse_timestamp(start_time)
    end_seconds = parse_timestamp(end_time)
    duration = end_seconds - start_seconds
    
    output_file = File.join(@temp_dir, "segment_#{index.to_s.rjust(4, '0')}.mp4")
    
    if File.exist?(output_file)
      log(sprintf('skip: segment exists[%s]', output_file), :info)
      return output_file
    end
    
    # Extract segment and add text overlay
    # Using drawtext filter to overlay the trail name
    cmd = [
      'ffmpeg',
      '-hwaccel', 'auto',
      '-i', video_path,
      '-ss', start_seconds.to_s,
      '-t', duration.to_s,
      '-vf', build_drawtext_filter(trail_name),
      '-c:v', 'libx264',
      '-c:a', 'aac',
      '-y',
      output_file
    ]
    
    run_command(cmd)
    output_file
  end

  def build_drawtext_filter(text)
    escaped_text = escape_drawtext_text(text)
    font_spec = if (fontfile = find_drawtext_fontfile)
      # Escape any colons in path for ffmpeg filter parsing
      "fontfile=#{fontfile.gsub(':', '\\:')}"
    else
      # Fall back to a common font name when fontconfig is available
      "font=Helvetica"
    end
    "drawtext=#{font_spec}:" \
    "text='#{escaped_text}':" \
    "fontsize=48:" \
    "fontcolor=white:" \
    "box=1:" \
    "boxcolor=black@0.5:" \
    "boxborderw=10:" \
    "x=(w-text_w)/2:" \
    "y=h-th-30,format=yuv420p"
  end
  
  def escape_drawtext_text(text)
    # Escape characters significant to ffmpeg drawtext parsing
    text
      .gsub('\\', '\\\\\\\\') # literal backslash
      .gsub(':', '\\\\:')     # option separator
      .gsub("'", "\\\\'")     # quote delimiter
  end
  
  def find_drawtext_fontfile
    candidates = [
      '/System/Library/Fonts/Supplemental/Andale Mono.ttf',
      '/System/Library/Fonts/Optima.ttc'
    ]
    candidates.find { |p| File.exist?(p) }
  end

  def concatenate_with_transitions
    if File.exist?(@output_file)
      log(sprintf('output already exists[%s], skipping concatenation', @output_file), :info)
      return
    end
    # Create segments with fade-out to white
    faded_segments = []
    
    @segment_files.each_with_index do |segment, i|
      # Add fade to white at the end (except for last segment)
      if i < @segment_files.size - 1
        faded_file = File.join(@temp_dir, "faded_#{i.to_s.rjust(4, '0')}.mp4")
        if File.exist?(faded_file)
          log(sprintf('skip: faded segment exists[%s]', faded_file), :info)
        else
          # Get video duration only if needed
          duration = get_video_duration(segment)
          fade_start = duration - TRANSITION_DURATION
          
          cmd = [
            'ffmpeg',
            '-i', segment,
            '-vf', "fade=t=out:st=#{fade_start}:d=#{TRANSITION_DURATION}:color=white,format=yuv420p",
            '-c:v', 'libx264',
            '-c:a', 'copy',
            '-y',
            faded_file
          ]
          
          run_command(cmd)
        end
        faded_segments << faded_file
        
        # Create white frame transition
        transition_file = create_white_transition(segment, i)
        faded_segments << transition_file
      else
        # Last segment doesn't need fade out
        faded_segments << segment
      end
    end
    
    # Create concat file list
    concat_file = File.join(@temp_dir, 'concat_list.txt')
    File.write(concat_file, faded_segments.map { |f| "file '#{f}'" }.join("\n"))
    
    # Concatenate all segments
    cmd = [
      'ffmpeg',
      '-f', 'concat',
      '-safe', '0',
      '-i', concat_file,
      '-c:v', 'libx264',
      '-pix_fmt', 'yuv420p',
      '-c:a', 'aac',
      '-movflags', '+faststart',
      '-y',
      @output_file
    ]
    
    run_command(cmd)
  end

  def create_white_transition(reference_segment, index)
    transition_file = File.join(@temp_dir, "transition_#{index.to_s.rjust(4, '0')}.mp4")
    if File.exist?(transition_file)
      log(sprintf('skip: transition exists[%s]', transition_file), :info)
      return transition_file
    end
    
    # Get video properties from reference segment
    width, height, fps = get_video_properties(reference_segment)
    
    # Create a short solid white video (no black ramp)
    cmd = [
      'ffmpeg',
      '-f', 'lavfi',
      '-i', "color=white:s=#{width}x#{height}:r=#{fps}:d=#{TRANSITION_DURATION}",
      '-f', 'lavfi',
      '-i', 'anullsrc',
      '-vf', "format=yuv420p",
      '-c:v', 'libx264',
      '-c:a', 'aac',
      '-shortest',
      '-y',
      transition_file
    ]
    
    run_command(cmd)
    transition_file
  end

  def get_video_duration(video_file)
    cmd = [
      'ffprobe',
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      video_file
    ]
    
    output = `#{cmd.join(' ')}`.strip
    output.to_f
  end

  def get_video_properties(video_file)
    # Get width
    width_cmd = [
      'ffprobe',
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      video_file
    ]
    width = `#{width_cmd.join(' ')}`.strip.to_i
    
    # Get height
    height_cmd = [
      'ffprobe',
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=height',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      video_file
    ]
    height = `#{height_cmd.join(' ')}`.strip.to_i
    
    # Get fps
    fps_cmd = [
      'ffprobe',
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=r_frame_rate',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      video_file
    ]
    fps_str = `#{fps_cmd.join(' ')}`.strip
    # Parse fraction like "30/1"
    num, den = fps_str.split('/').map(&:to_i)
    fps = den > 0 ? (num.to_f / den.to_f) : 30.0
    
    [width, height, fps]
  end

  def run_command(cmd)
    cmd_str = cmd.join(' ')
    log(sprintf('running[%s]', cmd_str), :debug)
    status = nil
    Open3.popen2e(*cmd) do |stdin, stdout_and_err, wait_thr|
      stdin.close
      begin
        until stdout_and_err.eof?
          chunk = stdout_and_err.readpartial(4096)
          $stdout.write(chunk)
          $stdout.flush
        end
      rescue EOFError
        # stream closed
      end
      status = wait_thr.value
    end
    raise "Command failed: #{cmd_str}" unless status.success?
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  if ARGV.size != 2
    puts "Usage: #{$PROGRAM_NAME} <map.json> <output.mp4>"
    puts ""
    puts "Example map.json format:"
    puts <<~JSON
      {
        "/path/to/file.mp4": {
          "Trail Name 1": ["1:35", "2:05"],
          "Trail Name 2": ["5:20", "6:00"]
        },
        "/path/to/file2.mp4": {
          "Trail Name 3": ["10:00", "11:00"]
        }
      }
    JSON
    exit 1
  end

  map_file = ARGV[0]
  output_file = ARGV[1]

  unless File.exist?(map_file)
    log(sprintf('map file[%s] not found', map_file), :fatal)
  end

  compiler = VideoCompiler.new(map_file, output_file)
  compiler.compile
end