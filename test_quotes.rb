#!/usr/bin/env ruby

require 'minitest/autorun'
require_relative 'supercut'

# Tests that trail names with special characters (apostrophes, quotes, etc.)
# are correctly passed to ffmpeg's drawtext filter.
#
# The approach: write the label to a temp file and use textfile= instead of
# text=. The file content needs zero filter-level escaping. Only the file PATH
# needs quoting (for the filter option parser), and paths don't contain quotes.
class TestDrawtextEscaping < Minitest::Test
  def setup
    @compiler = VideoCompiler.new('dummy.json', 'dummy.mp4')
  end

  # --- quote_drawtext_value (used for file paths) ---

  def test_quote_simple_path
    result = @compiler.send(:quote_drawtext_value, '/tmp/label_0001.txt')
    assert_equal "'/tmp/label_0001.txt'", result
  end

  def test_quote_path_with_spaces
    result = @compiler.send(:quote_drawtext_value, '/System/Library/Fonts/Supplemental/Andale Mono.ttf')
    assert_equal "'/System/Library/Fonts/Supplemental/Andale Mono.ttf'", result
  end

  def test_quote_empty_string
    result = @compiler.send(:quote_drawtext_value, '')
    assert_equal "''", result
  end

  # --- build_drawtext_filter_raw uses textfile= not text= ---

  def test_drawtext_uses_textfile
    filter = @compiler.send(:build_drawtext_filter_raw, '/tmp/label.txt')
    assert_match(/textfile='\/tmp\/label\.txt'/, filter)
    refute_match(/\btext=/, filter, 'should use textfile= not text=')
  end

  def test_drawtext_has_expected_options
    filter = @compiler.send(:build_drawtext_filter_raw, '/tmp/label.txt')
    assert_match(/fontsize=48/, filter)
    assert_match(/fontcolor=white/, filter)
    assert_match(/boxcolor=black@0\.5/, filter)
  end

  # --- end-to-end: label file content is the raw trail name ---

  def test_label_file_contains_raw_text
    # Simulate what create_segment does: write trail name to file, read it back
    require 'tempfile'

    trail_names = [
      "and we're back",
      "fred's lunch",
      "sittin' up",
      'Trail "Name"',
      "it's a \"quoted\" trail",
      "colons:and:stuff",
      "commas,in,name",
      "back\\slash",
      "plain trail name",
    ]

    trail_names.each do |name|
      file = Tempfile.new('label')
      begin
        file.write(name)
        file.close
        assert_equal name, File.read(file.path),
          "File round-trip failed for: #{name.inspect}"
      ensure
        file.unlink
      end
    end
  end

  # --- build_segment_filter integration ---

  def test_segment_filter_structure
    filter = @compiler.send(:build_segment_filter, '/tmp/label.txt', 10, fade_color: 'white')
    parts = filter.split(',')
    assert_match(/^drawtext=/, parts[0], 'first filter should be drawtext')
    assert_match(/^fade=/, parts[1], 'second filter should be fade')
    assert_equal 'format=yuv420p', parts[2], 'third filter should be format'
  end

  def test_segment_filter_without_fade
    filter = @compiler.send(:build_segment_filter, '/tmp/label.txt', 10)
    parts = filter.split(',')
    assert_match(/^drawtext=/, parts[0])
    assert_equal 'format=yuv420p', parts[1], 'without fade, format should be second'
  end

  # --- quote_drawtext_value still handles edge cases for paths ---

  def test_quote_path_with_single_quote
    # Unusual but possible: path with apostrophe
    result = @compiler.send(:quote_drawtext_value, "/tmp/it's/label.txt")
    assert_equal "'/tmp/it\\'s/label.txt'", result
  end

  def test_quote_path_with_backslash
    result = @compiler.send(:quote_drawtext_value, '/tmp/a\\b/label.txt')
    assert_equal "'/tmp/a\\\\b/label.txt'", result
  end
end
