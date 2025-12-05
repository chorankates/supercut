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
      if clean_requested?
        remove_if_exists(@output_file)
      else
        log(sprintf('output already exists[%s]; skipping compile', @output_file), :info)
        return
      end
    end
    log(sprintf('reading map file[%s]', @map_file), :info)
    map = JSON.parse(File.read(@map_file))
    # Quick preview mode: generate credits-only and exit
    if ENV['SUPERCUT_CREDITS_PREVIEW'] == '1'
      log('credits preview mode enabled', :info)
      preview_style = credits_style
      # Build lines from map or synthetic
      lines = build_credits_lines(map)
      if lines.empty? || ENV['SUPERCUT_SYNTHETIC_CREDITS'] == '1'
        n = (ENV['SUPERCUT_CREDITS_PREVIEW_LINES'] || '50').to_i
        lines = build_synthetic_credits_lines(n)
      end
      if preview_style == 'scroll'
        log('rendering scrolling credits preview...', :info)
        file = create_scrolling_credits_clip_from_lines(lines)
        FileUtils.cp(file, @output_file)
      else
        log('rendering paginated credits preview...', :info)
        files = create_credits_clips_from_lines(lines)
        concat_file = File.join(@temp_dir, 'credits_preview_concat.txt')
        File.write(concat_file, files.map { |f| "file '#{f}'" }.join("\n"))
        cmd = [
          'ffmpeg', '-f', 'concat', '-safe', '0', '-i', concat_file,
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', '-y', @output_file
        ]
        run_command(cmd)
      end
      log(sprintf('credits preview written to[%s]', @output_file), :info)
      return
    end
    
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
    concatenate_with_transitions(map)
    
    log(sprintf('video compiled successfully[%s]', @output_file))
  end

  private
  
  def clean_requested?
    ENV['SUPERCUT_CLEAN'] == '1'
  end
  
  def remove_if_exists(path)
    return unless File.exist?(path)
    log(sprintf('clean: removing[%s]', path), :debug)
    FileUtils.rm_f(path)
  end

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
    
    if clean_requested? && File.exist?(output_file)
      remove_if_exists(output_file)
    end
    
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
  
  def credits_style
    style = (ENV['SUPERCUT_CREDITS_STYLE'] || 'pages').downcase
    %w[pages scroll].include?(style) ? style : 'pages'
  end
  
  def default_video_properties
    [1920, 1080, 30.0]
  end

  def concatenate_with_transitions(map)
    if File.exist?(@output_file)
      if clean_requested?
        remove_if_exists(@output_file)
      else
        log(sprintf('output already exists[%s], skipping concatenation', @output_file), :info)
        return
      end
    end
    # Create segments with fade-out to white
    faded_segments = []
    
    @segment_files.each_with_index do |segment, i|
      # Add fade to white at the end (except for last segment)
      if i < @segment_files.size - 1
        faded_file = File.join(@temp_dir, "faded_#{i.to_s.rjust(4, '0')}.mp4")
        if clean_requested? && File.exist?(faded_file)
          remove_if_exists(faded_file)
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
        # Last segment: fade out to black
        faded_file = File.join(@temp_dir, "faded_#{i.to_s.rjust(4, '0')}.mp4")
        if clean_requested? && File.exist?(faded_file)
          remove_if_exists(faded_file)
        else
          duration = get_video_duration(segment)
          fade_start = duration - TRANSITION_DURATION
          
          cmd = [
            'ffmpeg',
            '-i', segment,
            '-vf', "fade=t=out:st=#{fade_start}:d=#{TRANSITION_DURATION}:color=black,format=yuv420p",
            '-c:v', 'libx264',
            '-c:a', 'copy',
            '-y',
            faded_file
          ]
          
          run_command(cmd)
        end
        faded_segments << faded_file
      end
    end

    # Create and append credits clip(s) after the final segment
    if @segment_files.any?
      if credits_style == 'scroll'
        clip = create_scrolling_credits_clip(map, @segment_files.last)
        faded_segments << clip if clip
      else
        credits_clips = create_credits_clips(map, @segment_files.last)
        credits_clips.each { |clip| faded_segments << clip }
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
    if clean_requested? && File.exist?(transition_file)
      remove_if_exists(transition_file)
    end
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

  def create_credits_clips(map, reference_segment)
    width, height, fps = reference_segment ? get_video_properties(reference_segment) : default_video_properties
    font_size = 36
    line_spacing = 10
    top_bottom_margin = 120
    usable_height = [height - (2 * top_bottom_margin), height].max
    approx_line_px = font_size + line_spacing
    max_lines_per_page = [[(usable_height / approx_line_px).floor, 6].max, 40].min

    # Build header and content lines separately for flexible pagination
    date_str = Time.now.strftime('%Y-%m-%d')
    header_lines_first = ['Credits', '', "Generated on #{date_str}", '']
    content_lines = build_credits_lines(map)

    # Create pages
    pages = []
    remaining = content_lines.dup
    page_index = 0
    while remaining.any?
      page_index += 1
      if page_index == 1
        capacity = max_lines_per_page - header_lines_first.size
        page_body = remaining.shift(capacity)
        page_lines = header_lines_first + page_body
      else
        header_cont = ['Credits (cont.)', '']
        capacity = max_lines_per_page - header_cont.size
        page_body = remaining.shift(capacity)
        page_lines = header_cont + page_body
      end
      pages << page_lines
    end

    total_pages = pages.size
    clips = []
    pages.each_with_index do |page_lines, i|
      page_num = (i + 1).to_s.rjust(3, '0')
      credits_file = File.join(@temp_dir, "credits_page_#{page_num}.mp4")
      credits_txt_path = File.join(@temp_dir, "credits_page_#{page_num}.txt")
      if clean_requested? && File.exist?(credits_file)
        remove_if_exists(credits_file)
      end
      if clean_requested? && File.exist?(credits_txt_path)
        remove_if_exists(credits_txt_path)
      end
      if !File.exist?(credits_txt_path)
        # Optionally append page indicator at bottom if multiple pages
        page_lines_with_footer = if total_pages > 1
          page_lines + ['',
                        "Page #{i + 1} of #{total_pages}"]
        else
          page_lines
        end
        File.write(credits_txt_path, page_lines_with_footer.join("\n").rstrip + "\n")
      end
      unless File.exist?(credits_file)
        duration = compute_credits_duration_seconds(File.read(credits_txt_path))
        font_spec = if (fontfile = find_drawtext_fontfile)
          "fontfile=#{fontfile.gsub(':', '\\:')}"
        else
          "font=Helvetica"
        end
        textfile_escaped = credits_txt_path.gsub(':', '\\:')
        cmd = [
          'ffmpeg',
          '-f', 'lavfi',
          '-i', "color=black:s=#{width}x#{height}:r=#{fps}:d=#{duration}",
          '-f', 'lavfi',
          '-i', 'anullsrc',
          '-vf',
          [
            "drawtext=#{font_spec}:",
            "textfile='#{textfile_escaped}':",
            "fontsize=#{font_size}:",
            "fontcolor=white:",
            "line_spacing=#{line_spacing}:",
            "box=1:",
            "boxcolor=black@0.0:",
            "boxborderw=0:",
            "x=(w-text_w)/2:",
            "y=(h-text_h)/2",
            ",format=yuv420p,fade=t=in:st=0:d=0.5,fade=t=out:st=#{[duration - 0.6, 0.0].max}:d=0.6"
          ].join,
          '-c:v', 'libx264',
          '-c:a', 'aac',
          '-shortest',
          '-y',
          credits_file
        ]
        run_command(cmd)
      end
      clips << credits_file
    end
    clips
  end
  
  def create_credits_clips_from_lines(lines, reference_segment: nil)
    width, height, fps = reference_segment ? get_video_properties(reference_segment) : default_video_properties
    font_size = 36
    line_spacing = 10
    top_bottom_margin = 120
    usable_height = [height - (2 * top_bottom_margin), height].max
    approx_line_px = font_size + line_spacing
    max_lines_per_page = [[(usable_height / approx_line_px).floor, 6].max, 40].min
    pages = []
    remaining = lines.dup
    page_index = 0
    while remaining.any?
      page_index += 1
      header = page_index == 1 ? ['Credits', ''] : ['Credits (cont.)', '']
      capacity = max_lines_per_page - header.size
      body = remaining.shift(capacity)
      pages << (header + body)
    end
    total_pages = pages.size
    clips = []
    pages.each_with_index do |page_lines, i|
      page_num = (i + 1).to_s.rjust(3, '0')
      credits_file = File.join(@temp_dir, "credits_preview_page_#{page_num}.mp4")
      credits_txt_path = File.join(@temp_dir, "credits_preview_page_#{page_num}.txt")
      File.write(credits_txt_path, (page_lines + (total_pages > 1 ? ['', "Page #{i + 1} of #{total_pages}"] : [])).join("\n").rstrip + "\n")
      duration = compute_credits_duration_seconds(File.read(credits_txt_path))
      font_spec = if (fontfile = find_drawtext_fontfile)
        "fontfile=#{fontfile.gsub(':', '\\:')}"
      else
        "font=Helvetica"
      end
      textfile_escaped = credits_txt_path.gsub(':', '\\:')
      cmd = [
        'ffmpeg', '-f', 'lavfi', '-i', "color=black:s=#{width}x#{height}:r=#{fps}:d=#{duration}",
        '-f', 'lavfi', '-i', 'anullsrc',
        '-vf',
        [
          "drawtext=#{font_spec}:",
          "textfile='#{textfile_escaped}':",
          "fontsize=#{font_size}:",
          "fontcolor=white:",
          "line_spacing=#{line_spacing}:",
          "x=(w-text_w)/2:",
          "y=(h-text_h)/2",
          ",format=yuv420p,fade=t=in:st=0:d=0.5,fade=t=out:st=#{[duration - 0.6, 0.0].max}:d=0.6"
        ].join,
        '-c:v', 'libx264', '-c:a', 'aac', '-shortest', '-y', credits_file
      ]
      run_command(cmd)
      clips << credits_file
    end
    clips
  end

  def compute_credits_duration_seconds(text)
    line_count = text.lines.size
    base = 5.0
    per_line = 0.4
    [[base + (line_count * per_line), 8.0].max, 20.0].min
  end
  
  def compute_scroll_duration_seconds(lines_count, height, font_size, line_spacing, margin_top, margin_bottom, speed_px_per_s)
    approx_line_px = font_size + line_spacing
    text_height = (lines_count * approx_line_px)
    distance = height + margin_top + margin_bottom + text_height
    (distance / speed_px_per_s.to_f) + 0.5
  end

  def build_credits_text(map)
    lines = []
    lines << 'Credits'
    lines << ''
    date_str = Time.now.strftime('%Y-%m-%d')
    lines << "Generated on #{date_str}"
    lines << ''
    map.each do |video_path, trails|
      lines << File.basename(video_path.to_s)
      trails.each do |trail_name, timestamps|
        start_t, end_t = timestamps
        lines << "  • #{trail_name}: #{start_t} – #{end_t}"
      end
      lines << ''
    end
    lines.join("\n").rstrip + "\n"
  end
  
  def build_scrolling_credits_lines(map)
    date_str = Time.now.strftime('%Y-%m-%d')
    lines = ['Credits', '', "Generated on #{date_str}", '']
    lines.concat(build_credits_lines(map))
    lines
  end

  def build_credits_lines(map)
    lines = []
    map.each do |video_path, trails|
      lines << File.basename(video_path.to_s)
      trails.each do |trail_name, timestamps|
        start_t, end_t = timestamps
        lines << "  • #{trail_name}: #{start_t} – #{end_t}"
      end
      lines << ''
    end
    # Ensure at least one line to avoid empty page
    lines = ['No segments'] if lines.empty?
    lines
  end
  
  def build_synthetic_credits_lines(n)
    lines = ['Credits', '', "Generated on #{Time.now.strftime('%Y-%m-%d')}", '']
    lines << 'Synthetic Preview'
    (1..n).each do |i|
      lines << "  • Example Trail #{i}: #{format('%02d', i % 60)}:00 – #{format('%02d', (i + 1) % 60)}:00"
    end
    lines
  end
  
  def create_scrolling_credits_clip(map, reference_segment)
    lines = build_scrolling_credits_lines(map)
    create_scrolling_credits_clip_from_lines(lines, reference_segment: reference_segment)
  end
  
  def create_scrolling_credits_clip_from_lines(lines, reference_segment: nil, width: nil, height: nil, fps: nil)
    if reference_segment
      w, h, r = get_video_properties(reference_segment)
    else
      w, h, r = width || 1920, height || 1080, fps || 30.0
    end
    font_size = 42
    line_spacing = 12
    margin_top = 80
    margin_bottom = 120
    speed_px_per_s = (ENV['SUPERCUT_SCROLL_SPEED'] || '80').to_i
    duration = compute_scroll_duration_seconds(lines.size, h, font_size, line_spacing, margin_top, margin_bottom, speed_px_per_s)
    credits_file = File.join(@temp_dir, 'credits_scroll.mp4')
    credits_txt_path = File.join(@temp_dir, 'credits_scroll.txt')
    if clean_requested? && File.exist?(credits_file)
      remove_if_exists(credits_file)
    end
    if clean_requested? && File.exist?(credits_txt_path)
      remove_if_exists(credits_txt_path)
    end
    File.write(credits_txt_path, lines.join("\n").rstrip + "\n")
    font_spec = if (fontfile = find_drawtext_fontfile)
      "fontfile=#{fontfile.gsub(':', '\\:')}"
    else
      "font=Helvetica"
    end
    textfile_escaped = credits_txt_path.gsub(':', '\\:')
    # Scroll upward: start below bottom (h + margin_bottom) and move up at speed
    draw = [
      "drawtext=#{font_spec}:",
      "textfile='#{textfile_escaped}':",
      "fontsize=#{font_size}:",
      "fontcolor=white:",
      "line_spacing=#{line_spacing}:",
      "x=(w-text_w)/2:",
      "y=h+#{margin_bottom}-(t*#{speed_px_per_s})"
    ].join
    cmd = [
      'ffmpeg',
      '-f', 'lavfi', '-i', "color=black:s=#{w}x#{h}:r=#{r}:d=#{duration}",
      '-f', 'lavfi', '-i', 'anullsrc',
      '-vf', "#{draw},format=yuv420p,fade=t=in:st=0:d=0.5,fade=t=out:st=#{[duration - 0.6, 0.0].max}:d=0.6",
      '-c:v', 'libx264', '-c:a', 'aac', '-shortest', '-y', credits_file
    ]
    run_command(cmd)
    credits_file
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