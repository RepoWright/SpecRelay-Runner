# frozen_string_literal: true

require "time"

module SpecrelayRunner
  # How one stored connection is DESCRIBED, for every surface that describes one (MVP-0021).
  #
  # The dashboard list, the dashboard detail view, `connections list`, and `connections show`
  # all render the same facts, and the rules about which facts may appear where are security
  # rules — so they live in one place instead of being re-decided per screen:
  #
  #   - The TOP-LEVEL summary shows no absolute local path. A dashboard is the screen most
  #     likely to end up in a screenshot, a pasted terminal transcript, or a support ticket,
  #     and an absolute path names the operator's machine layout and often their username.
  #   - The DETAIL view does show it, because at that point the operator has asked about one
  #     specific connection, the path is the fact they most often need (it is what a wrong
  #     checkout looks like), and it is already in their own local state file.
  #   - Neither shows anything credential-shaped. There is nothing to filter: the runner's
  #     local state carries no secret at all, which is exactly why it can be rendered freely.
  #     Repository URLs still pass through Redaction, because a remote can carry userinfo.
  #
  # Every value is width-bounded so a narrow terminal degrades to truncation rather than to
  # wrapped, misaligned rows that hide which action a highlighted line would take.
  module ConnectionView
    ROW_SEPARATOR = " · "

    module_function

    # The one-line list row: enough to choose safely, and nothing that identifies the host.
    #
    # THE PROJECT LEADS (RUNNER-0001 scope 1). An operator connected an application, not a
    # workspace key, and the row they scan should say so. The workspace key stays on the row
    # immediately after it — it is the deterministic routing key `--workspace` takes, and with
    # two connections to the same project it is the only thing that tells them apart.
    #
    # Every field has to survive an 80-column terminal, so the repository appears as
    # `owner/repo@branch` rather than as a full URL. That is the part an operator actually reads
    # to tell two connections apart, and a row whose branch and age get truncated away is a row
    # that cannot be chosen from — the detail view carries the full URL.
    #
    # The row separates fields more tightly than a title does, because the width budget is spent
    # on the fields themselves: a workspace key and a repository name that repeat the same words
    # already cost most of the 80 columns.
    def summary_line(connection, default: false, width: 100)
      fields = [ "#{selection_label(connection, separator: ROW_SEPARATOR)}#{' (default)' if default}",
                 "#{short_repository_label(connection)}@#{present(connection.default_branch)}",
                 age(connection) ]
      clip(fields.join(ROW_SEPARATOR), width)
    end

    # How one connection is NAMED wherever it has to be identified in one string: the project
    # and then its workspace key. An older local record with no project metadata falls back
    # visibly to the workspace key alone — never to a guessed name, and never to a bare dash
    # that would leave the row unidentifiable.
    def selection_label(connection, separator: "  ·  ")
      project = project_name(connection)
      project.nil? ? present(connection.workspace_key) : "#{project}#{separator}#{connection.workspace_key}"
    end

    # The stored project identity, or nil when this record predates it.
    def project_name(connection)
      label = project_label(connection)
      label == "—" ? nil : label
    end

    # `owner/repo`, dropping the host, transport, and any userinfo. Two connections on the same
    # host are told apart by owner/repo, and the host is the same for every one of them in
    # practice.
    def short_repository_label(connection)
      identity = RepositoryCheck.repository_identity(connection.repository_url)
      return present(connection.repository_url) if identity.empty?

      identity.split("/").last(2).join("/")
    end

    # The detail view's ordered label/value pairs. An ordered array rather than a Hash because
    # the ORDER is part of the design: identity first, then what it points at, then when.
    def detail_rows(connection, default: false, readiness: nil)
      [
        [ "Project", project_label(connection) ],
        [ "Workspace", "#{connection.workspace_key} (#{present(connection.workspace_display_name)})" ],
        [ "Platform", present(connection.base_url) ],
        [ "Repository", repository_label(connection) ],
        [ "Default branch", present(connection.default_branch) ],
        [ "Local checkout", present(connection.local_path) ],
        [ "Runner", runner_label(connection) ],
        [ "Connected", "#{present(connection.connected_at)} (#{age(connection)})" ],
        [ "Default workspace", default ? "yes — chosen explicitly on this machine" : "no" ],
        [ "Last local readiness", readiness || "not tested on this machine yet" ]
      ]
    end

    # The project key is shown only when it differs from the slug: repeating an identical value
    # in brackets is noise in a row that has to stay readable at 80 columns.
    def project_label(connection)
      slug = present(connection.project_slug)
      key = connection.project_key.to_s.strip
      key.empty? || key == slug ? slug : "#{slug} (#{key})"
    end

    # Redacted because a git remote can legitimately carry userinfo, which must never be
    # rendered even though the runner never stores a credential of its own here.
    def repository_label(connection) = Redaction.redact(present(connection.repository_url))

    def runner_label(connection)
      "#{present(connection.runner_display_name)} — #{present(connection.runner_id)} " \
        "(#{present(connection.runner_public_id)})"
    end

    # A coarse relative age. Deliberately coarse: "3 days ago" is what an operator reasons
    # about when deciding whether a connection is stale, and an exact timestamp is one row
    # below in the detail view anyway.
    def age(connection)
      connected = Time.parse(connection.connected_at.to_s)
      seconds = (Time.now.utc - connected.utc).to_i
      return "just now" if seconds < 60
      return "#{seconds / 60}m ago" if seconds < 3600
      return "#{seconds / 3600}h ago" if seconds < 86_400

      "#{seconds / 86_400}d ago"
    rescue ArgumentError, TypeError
      "at an unknown time"
    end

    def present(value)
      text = value.to_s.strip
      text.empty? ? "—" : text
    end

    # Truncation, never wrapping. A wrapped row in a keyboard menu shifts every row below it
    # and can leave a destructive action under a line the operator thinks is something else.
    def clip(text, width)
      limit = [ width.to_i, 24 ].max
      text.length <= limit ? text : "#{text[0, limit - 1]}…"
    end
  end
end
