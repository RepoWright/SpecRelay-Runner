# frozen_string_literal: true

require_relative "test_helper"
require "json"

# MAPIAI-97 CR-006 — the one private-host-path rule, on its own terms.
#
# Two matrices, because the rule has two halves and getting either wrong is a real defect: what it
# must remove, and what it must leave completely alone. The second half is not politeness — the
# Product Owner asked for RAW operational output, so a rule that quietly ate ports, Compose names
# or repository-relative paths would be a different bug wearing this one's clothes.
#
# Every case is evaluated before asserting, so a failure names all of them at once.
class PrivatePathsTest < Minitest::Test
  P = SpecrelayRunner::PrivatePaths
  REDACTED = SpecrelayRunner::PrivatePaths::REDACTION

  # ---- what must go ---------------------------------------------------------------------

  def removals
    {
      "a macOS home path" => "/Users/person/project/app.rb",
      "a macOS task worktree" => "/Users/person/dev/.specrelay-runs/worktree/environments/X/workspace",
      "a linux home path" => "/home/person/project/app.rb",
      "the shared temporary root" => "/tmp/build-1234/out.json",
      "a macOS private temporary directory" => "/var/folders/c1/zhq50sd/T/specrelay-runner-x/f",
      "its /private form" => "/private/var/folders/c1/zhq50sd/T/specrelay-runner-x/f",
      "the other private temporary root" => "/private/tmp/scratch/out.json",
      "a file url" => "file:///Users/person/notes.txt",
      "a windows user profile" => 'C:\\Users\\person\\project\\app.rb',
      "a windows user profile with forward slashes" => "C:/Users/person/project/app.rb"
    }
  end

  def test_every_private_host_path_shape_is_replaced_by_the_one_placeholder
    leaked = removals.reject do |_name, path|
      sanitized = P.sanitize("the project reported #{path} while working")
      sanitized.include?(REDACTED) && !sanitized.include?("person") && !sanitized.include?("folders")
    end

    assert_equal [], leaked.keys, "these host paths survived sanitization"
  end

  # The surrounding sentence is still a sentence: only the path is replaced, and the punctuation
  # that ended it stays outside the placeholder.
  def test_only_the_path_is_replaced_and_the_sentence_survives
    assert_equal "created #{REDACTED}, then started it.",
                 P.sanitize("created /Users/person/dev/x, then started it.")
    assert_equal "see #{REDACTED}.", P.sanitize("see file:///home/person/a.txt.")
    assert_equal "\"worktree_path\":\"#{REDACTED}\",\"dirty\":false",
                 P.sanitize("\"worktree_path\":\"/Users/person/dev/x\",\"dirty\":false")
  end

  # ---- what must go, when the path contains spaces (CR-007 F8) --------------------------

  # A host path with a space in it is still one path. The rule used to stop at the first space,
  # which removed the username and left the directory and file names standing — a partial removal
  # that reads as a redaction and is not one. Project output writes such a path in three
  # unambiguous ways — quoted (a JSON value is one), with its spaces escaped, or percent-encoded
  # — and all three have to be removed whole.
  SPACED = "Jane Doe/Secret Project/private notes.txt"
  # Every part of that fixture. None may survive in any form.
  FRAGMENTS = %w[Jane Doe Secret Project notes.txt].freeze

  def spaced_removals
    {
      "a double-quoted POSIX path" => "created \"/Users/#{SPACED}\" and started it",
      "a single-quoted POSIX path" => "cannot open '/home/#{SPACED}': no such file",
      "a JSON member" => "{\"worktree_path\":\"/Users/#{SPACED}\",\"dirty\":false}",
      "a quoted windows user profile" =>
        "wrote \"C:\\Users\\Jane Doe\\Secret Project\\private notes.txt\" ok",
      "a quoted macOS temporary directory" => "removing \"/private/var/folders/#{SPACED}\", done",
      "a file url with literal spaces" => "see \"file:///Users/#{SPACED}\" for detail",
      "a file url with encoded spaces" =>
        "see file:///Users/Jane%20Doe/Secret%20Project/private%20notes.txt now",
      "a shell-escaped path" => "cd /Users/Jane\\ Doe/Secret\\ Project && ls"
    }
  end

  def test_no_part_of_a_spaced_private_path_survives
    leaked = spaced_removals.reject do |_name, text|
      sanitized = P.sanitize(text)
      sanitized.include?(REDACTED) && FRAGMENTS.none? { |fragment| sanitized.include?(fragment) }
    end

    assert_equal [], leaked.keys, "these spaced host paths were only partly removed"
  end

  # The value's terminator and everything after it belong to the document, not to the path.
  def test_the_quote_and_everything_after_it_survive
    assert_equal "created \"#{REDACTED}\" and started it",
                 P.sanitize("created \"/Users/#{SPACED}\" and started it")
    assert_equal "cannot open '#{REDACTED}': no such file",
                 P.sanitize("cannot open '/home/#{SPACED}': no such file")
    assert_equal "cd #{REDACTED} && ls", P.sanitize("cd /Users/Jane\\ Doe/Secret\\ Project && ls")
  end

  # The line a real `status --json` produces: a service link the operator needs, a spaced host
  # path they must not see, and another member of the same document. An over-greedy rule takes
  # the URL or the rest of the document with it, and fails here rather than quietly.
  def test_a_spaced_path_between_a_service_url_and_another_json_member_loses_only_the_path
    text = "{\"primary_url\":\"http://127.0.0.1:5173\",\"worktree_path\":\"/Users/#{SPACED}\",\"dirty\":false}"

    assert_equal "{\"primary_url\":\"http://127.0.0.1:5173\",\"worktree_path\":\"#{REDACTED}\",\"dirty\":false}",
                 P.sanitize(text)
  end

  # ---- what must go, in the JSON a project command actually prints (CR-008 F10) ---------

  # A Windows path inside JSON is not the path a terminal shows. `JSON.generate` escapes every
  # separator, so `C:\Users\...` reaches this rule as `C:\\Users\\...` and the previous grammar,
  # which accepted a single separator, matched none of it. These fixtures are GENERATED rather
  # than hand-written, because hand-written JSON is exactly how that was missed.
  WINDOWS = 'C:\\Users\\Jane Doe\\Secret Project\\file.txt'
  WINDOWS_FRAGMENTS = %w[Jane Doe Secret Project file.txt].freeze

  def json_removals
    {
      "a windows path with spaces" => { "worktree_path" => WINDOWS },
      "its forward-slash form" => { "worktree_path" => "C:/Users/Jane Doe/Secret Project/file.txt" },
      "an upper-case Users segment" => { "worktree_path" => 'C:\\USERS\\Jane Doe\\Secret Project\\file.txt' },
      "a lower-case users segment" => { "worktree_path" => 'c:\\users\\Jane Doe\\Secret Project\\file.txt' },
      "a mixed-case UsErS segment" => { "worktree_path" => 'D:\\UsErS\\Jane Doe\\Secret Project\\file.txt' },
      "an apostrophe inside the double-quoted value" =>
        { "worktree_path" => 'C:\\Users\\Jane\'s Laptop\\Secret Project\\file.txt' },
      "the path beside a loopback url and other members" =>
        { "primary_url" => "http://127.0.0.1:5173", "worktree_path" => WINDOWS,
          "dirty" => false, "branch" => "MAPIAI-97" }
    }
  end

  def test_no_part_of_a_json_escaped_windows_path_survives
    leaked = json_removals.reject do |_name, document|
      sanitized = P.sanitize(JSON.generate(document))
      sanitized.include?(REDACTED) && WINDOWS_FRAGMENTS.none? { |part| sanitized.include?(part) }
    end

    assert_equal [], leaked.keys, "these generated JSON documents kept part of a windows path"
  end

  # The document has to survive being sanitized: same quotes, same comma, same other members.
  def test_the_generated_document_keeps_every_member_around_the_removed_path
    document = { "primary_url" => "http://127.0.0.1:5173", "worktree_path" => WINDOWS,
                 "dirty" => false, "branch" => "MAPIAI-97" }

    assert_equal "{\"primary_url\":\"http://127.0.0.1:5173\",\"worktree_path\":\"#{REDACTED}\"," \
                 "\"dirty\":false,\"branch\":\"MAPIAI-97\"}",
                 P.sanitize(JSON.generate(document))
  end

  # A quote of the OTHER kind is path content, not a terminator.
  def test_the_opposite_quote_inside_a_quoted_path_does_not_end_it
    assert_equal "opened \"#{REDACTED}\" ok",
                 P.sanitize("opened \"/Users/Jane's Project/notes.txt\" ok")
    assert_equal "opened '#{REDACTED}' ok",
                 P.sanitize("opened '/Users/Jane \"The Boss\" Doe/notes.txt' ok")
  end

  # The bound {PreviewOutput} holds back is derived from this rule, so it is asserted against the
  # rule rather than trusted: no root this matrix contains may be longer than the published bound.
  def test_the_published_root_bound_is_the_longest_root_this_rule_matches
    longest = removals.values.map { |path| path[P::ROOT].to_s.bytesize }.max

    assert_equal longest, P::LONGEST_ROOT_BYTES
  end

  # ---- what must stay -------------------------------------------------------------------

  def survivors
    {
      "a loopback service url" => "open http://127.0.0.1:5173 to see it",
      "a loopback url with a port and root path" => "primary http://127.0.0.1:5174/",
      "an https url whose own path says Users" => "see https://example.com/Users/person/guide",
      "an https url whose own path says home" => "see https://docs.example.com/home/getting-started",
      "a pull request url" => "rebuilt from https://github.com/SpecRelay/App/pull/7",
      "a repository-relative path" => "edited app/services/run.rb and lib/x.rb",
      "a task id" => "starting MAPIAI-97-provide-live-task-preview-urls-for-human-approval",
      "a port block" => "branch X · slot 4 · ports 5100-5199",
      "a compose project name" => "compose project srt-mapiai-97-demo-20b930",
      "a bare system path" => "using /usr/bin/git and /opt/homebrew/bin/docker",
      "ordinary prose" => "the task environment reports 2 services, both healthy",
      "a git sha" => "head 4a22cc33f0e1b2c3d4e5f60718293a4b5c6d7e8f",
      "an https url with an encoded space, a query and a fragment" =>
        "see https://example.com/Users/Jane%20Doe/guide?tab=1#top",
      "a quoted https url whose own path has a literal space" =>
        "open \"https://example.com/home/Jane Doe/guide\"",
      "a repository-relative path containing a space" => "edited app/services/My Service.rb",
      "prose that happens to name a project" => "the Secret Project branch is ready in 2 repositories",
      "ordinary quoted prose" => "it said \"no such task environment\" and stopped",
      "a repository-relative windows-looking path" => "edited app\\services\\run.rb",
      "an https url with an encoded backslash and a fragment" =>
        "see https://example.com/a%5Cb/guide?tab=1#top",
      "a bare Users word" => "the Users table has 2 rows"
    }
  end

  def test_operational_content_and_safe_urls_come_back_byte_identical
    altered = survivors.reject { |_name, text| P.sanitize(text) == text }

    assert_equal [], altered.keys, "these were changed but had to come back byte for byte"
  end

  # The one case where a URL and a path meet: a service link on the same line as a worktree path.
  # The link is evidence the operator needs; the path is not.
  def test_a_safe_url_beside_a_private_path_keeps_the_url_and_loses_the_path
    text = "serving http://127.0.0.1:5173 from /Users/person/dev/checkout"

    assert_equal "serving http://127.0.0.1:5173 from #{REDACTED}", P.sanitize(text)
  end

  # A summary whose entire content was a path is not evidence. This is the analyzer's rule, kept
  # here with the pattern it depends on.
  def test_text_that_was_only_a_path_is_not_meaningful
    refute P.meaningful?(P.sanitize("file:///Users/person/only/a/path.txt"))
    assert P.meaningful?(P.sanitize("read /Users/person/a.rb and found 2 issues"))
  end
end
