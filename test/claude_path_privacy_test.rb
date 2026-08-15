# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/claude_stream_json"

# MAPIAI-77 — an absolute local filesystem path is private even when it carries no credential.
# MAPIAI-60 CR-005 deliberately made ordinary paths public; the live MAPIAI-73 run then proved
# that this publishes the developer's username, home layout, private temporary directories and
# task-worktree location on both live-progress surfaces.
#
# The roots below are FIXTURES, not this machine's directories. `ClaudeStream` decides on path
# TEXT — a live transcript names files that do not exist yet — so nothing here needs to exist,
# and the assertions hold identically on a macOS and a Linux host.
class ClaudePathPrivacyTest < Minitest::Test
  J = ClaudeStreamJson
  PLACEHOLDER = "[LOCAL_PATH]"

  MAC_ROOT = "/Users/dev-fixture/dev/acme/checkout"
  LINUX_ROOT = "/home/dev-fixture/dev/acme/checkout"
  WORKTREE = "/Users/dev-fixture/dev/acme/.specrelay-runs/worktree/environments/MAPIAI-77/workspace"

  def setup = @seen = []

  # ---- S01: a macOS path inside the verified implementation checkout ------

  def test_s01_an_in_root_macos_path_renders_as_a_repository_relative_path
    text = transcript(J.read_call("#{MAC_ROOT}/app/services/run.rb"),
                      J.read_result("toolu_read", "#{MAC_ROOT}/app/services/run.rb", "class Run\nend\n"))

    assert_includes text, "app/services/run.rb"
    assert_private_absent text
    refute_includes text, PLACEHOLDER, "a provable in-root path must stay useful"
    assert_includes text, "class Run", "content must survive the path policy"
  end

  # ---- S02: the same rule on a Linux-rooted checkout ----------------------

  def test_s02_an_in_root_linux_path_renders_as_a_repository_relative_path
    text = transcript(J.bash_call("ruby #{LINUX_ROOT}/lib/thing.rb", description: "Run the script"),
                      root: LINUX_ROOT)

    assert_includes text, "ruby lib/thing.rb"
    assert_private_absent text
  end

  # ---- S03: the task worktree, its exact root, and a prefix collision -----

  def test_s03_the_exact_worktree_root_renders_as_a_single_dot
    text = transcript(J.bash_call("cd #{WORKTREE} && bin/rails test"), root: WORKTREE)

    assert_includes text, "cd . && bin/rails test"
    assert_private_absent text
  end

  def test_s03_a_worktree_descendant_renders_relative_without_the_worktree_location
    text = transcript(J.edit_call("#{WORKTREE}/lib/specrelay_runner/claude_stream.rb", "a", "b"),
                      root: WORKTREE)

    assert_includes text, "lib/specrelay_runner/claude_stream.rb"
    refute_includes text, ".specrelay-runs"
    refute_includes text, "environments"
    assert_private_absent text
  end

  # `/repo` must not contain `/repo-copy`. A lexical prefix is not containment.
  def test_s03_a_lexical_prefix_collision_is_not_containment
    text = transcript(J.read_call("#{WORKTREE}-copy/lib/secret.rb"), root: WORKTREE)

    assert_includes text, PLACEHOLDER
    refute_includes text, "secret.rb"
    assert_private_absent text
  end

  # `..` may not walk out of the approved root and stay readable.
  def test_s03_a_traversal_span_never_establishes_containment
    text = transcript(J.read_call("#{MAC_ROOT}/../../Documents/private/notes.md"))

    assert_includes text, PLACEHOLDER
    refute_includes text, "Documents"
    assert_private_absent text
  end

  # ---- S04: a home-directory path outside the checkout --------------------

  def test_s04_an_out_of_root_home_path_is_replaced_whole
    text = transcript(J.read_call("/Users/dev-fixture/Documents/acme-customer/contract.pdf"))

    assert_includes text, PLACEHOLDER
    refute_includes text, "acme-customer"
    refute_includes text, "contract.pdf", "the basename can disclose a customer or project"
    assert_private_absent text
  end

  # ---- S05: private temporary directories ---------------------------------

  def test_s05_private_temporary_paths_are_replaced_whole
    temps = [ "/private/var/folders/q7/9mzk0000gn/T/claude-9182/packet.json",
              "/private/tmp/specrelay-9182/staging.json",
              "/tmp/specrelay-9182/bridge.sock",
              "/var/tmp/spec-cache/answer.md" ]
    text = transcript(*temps.map { |path| J.read_call(path) })

    assert_equal temps.length, text.scan(PLACEHOLDER).length
    %w[folders 9mzk0000gn claude-9182 specrelay-9182 bridge.sock spec-cache].each do |segment|
      refute_includes text, segment
    end
  end

  # ---- S06: one path inside longer narration, with punctuation ------------

  def test_s06_only_the_path_span_changes_inside_narration
    text = transcript(J.narration(
      "I read /Users/dev-fixture/Documents/notes.md, then stopped (see /Users/dev-fixture/log.txt)."
    ))

    assert_includes text, "I read #{PLACEHOLDER}, then stopped (see #{PLACEHOLDER})."
    assert_private_absent text
  end

  # A sentence's closing period is punctuation around the span, not the last character of a
  # filename, and it must survive on both sides of the policy.
  def test_s06_a_path_that_ends_a_sentence_keeps_its_punctuation
    text = transcript(J.narration("Wrote /Users/dev-fixture/Desktop/report.md. Wrote " \
                                  "#{MAC_ROOT}/app/a.rb. Done."))

    assert_includes text, "Wrote #{PLACEHOLDER}. Wrote app/a.rb. Done."
    assert_private_absent text
  end

  # ---- S07: several spans in one line, in the provider's own order --------

  def test_s07_every_span_in_one_line_is_sanitized_independently_and_in_order
    text = transcript(J.bash_call(
      "diff #{MAC_ROOT}/app/a.rb /Users/dev-fixture/Desktop/b.rb #{MAC_ROOT}/app/c.rb"
    ))

    assert_includes text, "diff app/a.rb #{PLACEHOLDER} app/c.rb"
    refute_includes text, "Desktop"
    assert_private_absent text
  end

  # ---- S08: the negative controls this policy must not corrupt ------------

  def test_s08_relative_paths_urls_refs_prose_and_flags_survive_unchanged
    text = transcript(
      J.bash_call("bundle exec rspec spec/models | tail -5", description: "MAPIAI-77 on origin/main"),
      J.tool_call("WebFetch", "url" => "https://example.test/spec/models",
                              "note" => "read/write access is 50/50; see refs/heads/main"),
      J.bash_result("toolu_bash", stdout: "<h1>Hello</h1>\nlib/a.rb:12: ok\n")
    )

    [ "spec/models", "| tail -5", "MAPIAI-77", "origin/main", "https://example.test/spec/models",
      "read/write", "50/50", "refs/heads/main", "<h1>Hello</h1>", "lib/a.rb:12" ].each do |control|
      assert_includes text, control, "a safe control was corrupted by the path policy"
    end
    refute_includes text, PLACEHOLDER
  end

  # A `file://` URL is a local path wearing a scheme, and is the one scheme that is sanitized.
  def test_s08_a_file_url_is_sanitized_while_other_schemes_are_preserved
    text = transcript(J.tool_call("WebFetch", "url" => "https://example.test/a",
                                              "local" => "file:///Users/dev-fixture/Desktop/leak.md",
                                              "inside" => "file://#{MAC_ROOT}/app/a.rb"))

    assert_includes text, "https://example.test/a"
    assert_includes text, "local: #{PLACEHOLDER}"
    assert_includes text, "inside: app/a.rb"
    refute_includes text, "leak.md"
    assert_private_absent text
  end

  # ---- S09: credentials and a private key beside path content -------------

  PEM = <<~KEY
    -----BEGIN PRIVATE KEY-----
    QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj
    -----END PRIVATE KEY-----
  KEY

  def test_s09_credential_redaction_still_owns_secrets_while_paths_follow_this_policy
    secret = "ghp_#{'a' * 36}"
    surfaces = through_fan_out(
      J.bash_call("git push https://#{secret}@github.com/acme/app.git"),
      J.read_call("/Users/dev-fixture/.ssh/id_rsa"),
      J.read_result("toolu_read", "/Users/dev-fixture/.ssh/id_rsa", PEM),
      J.bash_result("toolu_bash", stdout: "wrote #{MAC_ROOT}/config/app.yml\n")
    )

    surfaces.each do |surface|
      refute_includes surface, secret
      refute_includes surface, "BEGIN PRIVATE KEY"
      refute_includes surface, "END PRIVATE KEY"
      refute_includes surface, "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="
      refute_includes surface, ".ssh"
      assert_includes surface, "[REDACTED]"
      assert_includes surface, PLACEHOLDER
      assert_includes surface, "wrote config/app.yml"
      assert_includes surface, "github.com/acme/app.git", "the evidence around a secret survives"
      assert_private_absent surface
    end
  end

  # ---- S10: one sanitized sequence, both lanes, every sink ----------------

  def test_s10_terminal_evidence_and_platform_receive_the_same_sanitized_sequence
    messages = [ J.narration("Editing #{MAC_ROOT}/app/a.css and /Users/dev-fixture/Desktop/b.css."),
                 J.edit_call("#{MAC_ROOT}/app/a.css", "color: red;", "color: green;"),
                 J.edit_result("toolu_edit", "#{MAC_ROOT}/app/a.css", "color: red;", "color: green;") ]
    terminal, delivered, evidence = through_fan_out(*messages)

    [ terminal, delivered, evidence ].each do |surface|
      assert_includes surface, "Editing app/a.css and #{PLACEHOLDER}."
      assert_includes surface, "-color: red;"
      assert_includes surface, "+color: green;"
      assert_private_absent surface
    end
    assert_equal normalize(terminal), normalize(delivered),
                 "one policy means one transcript on both surfaces"
  end

  # The specification lane has NO approved root, so every absolute path is unprovable.
  def test_s10_the_specification_lane_has_no_approved_root_and_shows_no_absolute_path
    lane = []
    decoder = SpecrelayRunner::ClaudeStream.new(sink: ->(_source, text) { lane << text })
    [ J.narration("Reading the packet at /private/var/folders/q7/T/claude-1/packet.json."),
      J.bash_call("cat #{MAC_ROOT}/spec.md"),
      J.bash_result("toolu_bash", stdout: "freshness: FRESH\n") ].each do |message|
      decoder.accept("stdout", JSON.generate(message))
    end

    text = lane.join("\n")
    assert_equal 2, text.scan(PLACEHOLDER).length
    assert_includes text, "freshness: FRESH", "useful progress must remain"
    assert_private_absent text
    refute_includes text, "packet.json"
  end

  # ---- S11: sanitization must precede BOTH clipping stages ----------------

  def test_s11_a_path_longer_than_both_clip_thresholds_leaks_neither_end
    long = "/Users/dev-fixture/SECRETHEAD/#{(1..300).map { |n| "segment#{n}" }.join('/')}/SECRETTAIL.rb"

    assert_operator long.length, :>, SpecrelayRunner::ClaudeStream::MAX_LINE_CHARS
    assert_operator long.bytesize, :>, SpecrelayRunner::ExecutorLogStream::MAX_LINE_BYTES

    through_fan_out(J.read_call(long), J.bash_result("toolu_bash", stdout: "cat #{long}\n")).each do |surface|
      refute_includes surface, "SECRETHEAD", "a clipped PREFIX must not survive"
      refute_includes surface, "SECRETTAIL", "a clipped SUFFIX must not survive"
      refute_includes surface, "segment1"
      assert_private_absent surface
    end
  end

  # ---- S12: unknown and malformed provider content still fail safely ------

  def test_s12_an_unknown_message_type_stays_silent_and_malformed_output_fails_closed
    silent = transcript({ "type" => "tool_progress_v2", "path" => "/Users/dev-fixture/secret/x.rb" })

    assert_empty silent.strip

    decoder = SpecrelayRunner::ClaudeStream.new(sink: ->(_s, text) { @seen << text },
                                                repository_path: MAC_ROOT)
    decoder.accept("stdout", JSON.generate([ "/Users/dev-fixture/secret/x.rb" ]))

    assert_equal SpecrelayRunner::ClaudeStream::FAILURE_UNREADABLE, decoder.close.failure
    assert_empty decoder.final_text
    assert_private_absent @seen.join("\n")
  end

  # ---- CR-001: the COMPLETE span, never its ASCII prefix -----------------
  #
  # Review 001 F1 measured four ordinary POSIX forms whose recognized prefix was replaced while
  # the private remainder stayed public. An outside basename or directory identifies a customer,
  # project or temporary artifact on its own, so a partial replacement is still a disclosure.

  CLIENT = "/Users/dev-fixture/Secret Client/report draft.md"

  def test_cr001_a_single_quoted_out_of_root_path_with_spaces_is_replaced_whole
    text = transcript(J.bash_call("cat '#{CLIENT}'"))

    assert_includes text, "cat '#{PLACEHOLDER}'", "the quotes are delimiters, not part of the span"
    assert_leak_absent text
  end

  def test_cr001_a_double_quoted_out_of_root_path_with_spaces_is_replaced_whole
    text = transcript(J.bash_call(%(cat "#{CLIENT}")))

    assert_includes text, %(cat "#{PLACEHOLDER}")
    assert_leak_absent text
  end

  def test_cr001_an_unquoted_escaped_space_path_is_replaced_whole
    text = transcript(J.bash_call("cat /Users/dev-fixture/Secret\\ Client/report.md"))

    assert_includes text, "cat #{PLACEHOLDER}"
    refute_includes text, "\\", "the escape must not stay attached to a private suffix"
    assert_leak_absent text
  end

  # `\w` is ASCII, so a Unicode directory used to end the span and restart it after the segment.
  def test_cr001_unicode_segments_do_not_split_one_path_into_public_fragments
    text = transcript(J.read_call("/Users/dev-fixture/Kundenprojekte/Ärzte-Portal/Bericht-Ünicode.md"))

    assert_equal 1, text.scan(PLACEHOLDER).length, "one path is one span: #{text}"
    [ "Kundenprojekte", "Ärzte-Portal", "Bericht", "Ünicode" ].each { |leak| refute_includes text, leak }
    assert_private_absent text
  end

  # An authority names ANOTHER host, so membership in this machine's approved root is unprovable.
  def test_cr001_a_file_url_with_another_authority_can_never_prove_membership
    text = transcript(J.tool_call("Read", "path" => "file://workstation/Users/dev-fixture/report.md"))

    assert_includes text, "> Read #{PLACEHOLDER}"
    refute_includes text, "workstation"
    refute_includes text, "report.md"
    assert_private_absent text
  end

  # The mirror of the rule: an empty or `localhost` authority IS this machine, so the same
  # containment test decides it.
  def test_cr001_an_empty_or_localhost_file_authority_is_evaluated_against_the_approved_root
    text = transcript(J.tool_call("Read", "empty" => "file://#{MAC_ROOT}/app/a.rb",
                                          "local" => "file://localhost#{MAC_ROOT}/app/b.rb",
                                          "away" => "file://localhost/Users/dev-fixture/Desktop/c.rb"))

    assert_includes text, "empty: app/a.rb"
    assert_includes text, "local: app/b.rb"
    assert_includes text, "away: #{PLACEHOLDER}"
    assert_private_absent text
  end

  # Containment still wins where it is provable, in every one of the new forms. This is a
  # REGRESSION control, not a failing-first case: an in-root span's replaced prefix is exactly the
  # private part, so the old partial match happened to render the same text the whole span does.
  def test_cr001_in_root_quoted_escaped_and_unicode_paths_stay_repository_relative
    text = transcript(J.bash_call("cp '#{MAC_ROOT}/app/My Views/a.erb' " \
                                  "#{MAC_ROOT}/app/My\\ Views/b.erb"),
                      J.read_call("#{MAC_ROOT}/app/Ärzte/Bericht.md"))

    assert_includes text, "cp 'app/My Views/a.erb' app/My\\ Views/b.erb"
    assert_includes text, "app/Ärzte/Bericht.md"
    refute_includes text, PLACEHOLDER
    assert_private_absent text
  end

  def test_cr001_the_new_forms_survive_embedding_with_safe_punctuation
    text = transcript(J.narration(
      "Read '#{CLIENT}' now, then /Users/dev-fixture/Ärzte/Bericht.md, and " \
      "finally file://workstation/Users/dev-fixture/x.md."
    ))

    assert_includes text, "Read '#{PLACEHOLDER}' now, then #{PLACEHOLDER}, and " \
                          "finally #{PLACEHOLDER}."
    assert_leak_absent text
  end

  # The wider grammar must not start eating safe text. These are the CR-001 negative controls.
  def test_cr001_the_wider_span_grammar_leaves_safe_controls_unchanged
    text = transcript(
      J.bash_call("bundle exec rspec spec/models --seed 1 | tail -5",
                  description: "MAPIAI-77 on origin/main, see refs/heads/main"),
      J.tool_call("WebFetch", "url" => "https://example.test/spec/models?q=a+b",
                              "note" => "read/write is 50/50; don't cd 'here'"),
      J.bash_result("toolu_bash", stdout: "café/menü.rb:12: ok\n<h1>Hello</h1>\nsed 's/a/b/'\n")
    )

    [ "spec/models", "--seed 1", "| tail -5", "MAPIAI-77", "origin/main", "refs/heads/main",
      "https://example.test/spec/models?q=a+b", "read/write", "50/50", "don't cd 'here'",
      "café/menü.rb:12", "<h1>Hello</h1>", "sed 's/a/b/'" ].each do |control|
      assert_includes text, control, "a safe control was corrupted by the wider span grammar"
    end
    refute_includes text, PLACEHOLDER
  end

  private

  # The four private facts review 001 measured surviving a partial replacement.
  def assert_leak_absent(text)
    [ "Secret Client", "report draft.md", "report.md", "Client", "workstation", "Ärzte",
      "Bericht" ].each do |leak|
      refute_includes text, leak, "a private path fragment survived the replacement"
    end
    assert_private_absent text
  end

  # Every private fact MAPIAI-73 proved reachable, checked on every surface.
  def assert_private_absent(text)
    [ "dev-fixture", "/Users/", "/home/", "/private/", "/tmp/", "/var/tmp" ].each do |leak|
      refute_includes text, leak, "a private local path fragment reached a live surface"
    end
  end

  def transcript(*messages, root: MAC_ROOT)
    seen = []
    decoder = SpecrelayRunner::ClaudeStream.new(sink: ->(_source, text) { seen << text },
                                                repository_path: root)
    messages.each { |message| decoder.accept("stdout", JSON.generate(message)) }
    seen.join("\n")
  end

  class RecordingProtocolClient
    attr_reader :accepted

    def initialize = @accepted = []

    def submit_protocol_event(claim:, event:, **)
      _ = claim
      @accepted << event
      { "lease" => { "state" => "active", "cancel_requested" => false } }
    end
  end

  # The REAL implementation-lane wiring: decoder -> ExecutorLogStream -> (terminal, report
  # evidence, Platform). Returns all three sinks' text.
  def through_fan_out(*messages, root: MAC_ROOT)
    client = RecordingProtocolClient.new
    emitter = SpecrelayRunner::EventEmitter.new(client: client, run_id: "run_77", attempt_id: "rex_77")
    io = StringIO.new
    stream = SpecrelayRunner::ExecutorLogStream.new(emitter: emitter, io: io, provider: "claude",
                                                    task_id: "MAPIAI-77")
    decoder = SpecrelayRunner::ClaudeStream.new(sink: stream.sink, repository_path: root)
    messages.each { |message| decoder.accept("stdout", JSON.generate(message)) }
    stream.send(:flush_all)

    [ io.string, client.accepted.map { |e| e["sanitized_log_chunk"].to_s }.join, stream.evidence_text ]
  end

  def normalize(text) = text.gsub(/^\s*\[claude:status\]\s?/, "").gsub(/\s+/, " ").strip
end
