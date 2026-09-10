# frozen_string_literal: true

module SpecrelayRunner
  module Specification
    # A parsed, validated READ of the specification-creation assignment payload Platform
    # builds in Runner::Api::SpecCreationPayload (MVP-0025 scope 3).
    #
    # It exists so that every later stage — preflight, evidence gathering, the generation
    # packet, the writer, the result — reads ONE checked object rather than digging into a
    # nested Hash with `dig` and discovering a missing field halfway through a write. That
    # ordering is the whole point of MVP-0026 criterion 5: a malformed assignment must be a
    # refusal BEFORE any output file exists, and it can only be that if the validation
    # happens here, at parse time, rather than at the first place a field is needed.
    #
    # It is a pure value object. It performs no I/O, makes no Platform call, and reads
    # nothing outside the payload it was handed.
    class Assignment
      # Raised when the payload is not a usable specification assignment. Carries the
      # operator-facing reason; Preflight turns it into the `assignment_malformed`
      # refusal class rather than letting it escape as a crash.
      Malformed = Class.new(StandardError)

      RUN_TYPE = "spec_creation"

      # The fields an assignment MUST carry for generation to be possible at all. Each is
      # a path into the payload plus the operator-facing name used in the refusal message.
      # A table rather than ten guard clauses: the list is the contract, and a reader
      # checking "what does the runner require?" should find one place that answers it.
      REQUIRED = [
        [ %w[run id], "run.id" ],
        [ %w[claim runner_execution_id], "claim.runner_execution_id" ],
        [ %w[work_item issue_key], "work_item.issue_key" ],
        [ %w[input_bundle content_markdown], "input_bundle.content_markdown" ],
        [ %w[specification_target repository_url], "specification_target.repository_url" ],
        [ %w[specification_target specification_root], "specification_target.specification_root" ],
        [ %w[workspace workspace_key], "workspace.workspace_key" ],
        # The TASK ENVIRONMENT the analysis is performed in, and the project's own command for
        # building it. Required rather than optional: workspace-grounded generation reconstructs
        # the ticket's canonical task worktree and reads the real multi-repository source there,
        # so an assignment naming no task and no branch describes work this build cannot do, and
        # reading a missing one as "no task" would point the worktree owner at an empty branch.
        # They are the SAME three fields the implementation lane already carries.
        [ %w[run task_id], "run.task_id" ],
        [ %w[run canonical_branch], "run.canonical_branch" ],
        [ %w[workspace worktree_create_command], "workspace.worktree_create_command" ]
      ].freeze

      # True when this payload is a specification assignment. Reads the discriminator
      # defensively, because an OLDER Platform that predates MVP-0025 sends no `run.type`
      # at all and the correct reading of a missing discriminator is "not a specification
      # assignment" — the implementation path, which is all such a Platform can send.
      def self.specification?(payload) = payload.to_h.dig("run", "type") == RUN_TYPE

      # Parse and validate, or raise Malformed. Deliberately raising rather than returning
      # a nullable: there is no partially usable assignment, and a caller that forgot to
      # check a nil would proceed into evidence gathering with no issue key.
      def self.parse(payload) = new(payload).tap(&:validate!)

      def initialize(payload)
        @payload = payload.to_h
      end

      def validate!
        unless self.class.specification?(payload)
          raise Malformed, "assignment is not a specification-creation run (run.type=#{payload.dig('run', 'type').inspect})"
        end

        missing = REQUIRED.reject { |path, _| present?(payload.dig(*path)) }.map(&:last)
        raise Malformed, "assignment is missing required generation data: #{missing.join(', ')}" if missing.any?

        validate_bundle_complete!
        validate_previous_accepted_package!
        self
      end

      # MAPIAI-87 CR-001 F1 — the continuation field is required and nullable on every assignment,
      # and this lane refuses a malformed one for the same reason the implementation lane does:
      # absence is not "no previous implementation", and a partial block would reach the writer as
      # apparently complete context. One shared validator, so the two lanes cannot drift.
      def validate_previous_accepted_package!
        reason = PreviousAcceptedPackage::Input.refusal(payload)
        raise Malformed, reason if reason
      end

      # An INCOMPLETE bundle is refused here rather than generated from with warnings.
      # Platform already refuses to make such a run claimable (Run#spec_creation_bundle_assignable?),
      # so a runner seeing one has been handed an assignment its own Platform says is not
      # assignable — which is a contract violation, not a degraded input. Writing a
      # specification from inputs the product classified as blocking is exactly the
      # "smoothing it over" that scope 4 forbids.
      def validate_bundle_complete!
        return if section("input_bundle")["complete"] == true

        blocking = Array(section("input_bundle")["blocking_inputs"]).length
        raise Malformed, "the input bundle is not complete (#{blocking} blocking " \
                         "#{blocking == 1 ? 'input' : 'inputs'}); a specification must not be written from it"
      end

      def run_id = section("run")["id"].to_s
      def run_state = section("run")["state"].to_s
      def runner_execution_id = section("claim")["runner_execution_id"].to_s
      # The runner identity Platform recorded for this claim — this runner's own configured id,
      # echoed back. MAPIAI-62 records it in an isolated workspace's metadata and re-checks it at
      # publication, so a workspace another runner identity created on a shared machine is
      # foreign state rather than resumable state.
      def runner_id = section("claim")["runner_id"].to_s
      def runner_display_name = section("claim")["runner_display_name"].to_s
      def issue_key = section("work_item")["issue_key"].to_s
      def issue_url = section("work_item")["issue_url"].to_s
      def issue_title = section("work_item")["title"].to_s
      def workspace_key = section("workspace")["workspace_key"].to_s
      def workspace_display_name = section("workspace")["display_name"].to_s

      # The task environment this specification is analysed in, in the implementation lane's own
      # vocabulary. Read here so {Workspace} can be built from ONE checked object: the runner
      # never derives a task id from an issue key, never invents a branch, and never composes a
      # create command — a runner that did would be maintaining a second layout convention
      # alongside the project's own `bin/worktree`.
      def task_id = section("run")["task_id"].to_s
      def canonical_branch = section("run")["canonical_branch"].to_s
      def worktree_create_command = section("workspace")["worktree_create_command"].to_s
      def run_url = section("links")["run_url"].to_s
      def bundle_markdown = section("input_bundle")["content_markdown"].to_s
      def bundle_url = section("input_bundle")["url"].to_s
      def bundle_trace_id = section("input_bundle")["trace_id"].to_s
      def repository_url = target["repository_url"].to_s
      def specification_root = target["specification_root"].to_s
      def default_branch = target["default_branch"].to_s
      def target_owner = target["owner"].to_s
      def target_repository = target["repository"].to_s

      # MVP-0028 decision D6 — the pull request Jira's `Spec PR` field already named for this
      # TICKET at THIS run's own intake, or "" for a first specification. Present on a
      # `specification_revision` block Platform sends on EVERY spec_creation assignment, unlike
      # `existing_pull_request_url` below, which only exists on a publication assignment. A
      # generation that finds one here is a REVISION: {Preflight} validates it exactly as
      # {ExistingPullRequest} validates a publication's, then reads the previous package from its
      # branch as revision context.
      def revision_pull_request_url = section("specification_revision")["existing_pull_request_url"].to_s

      # MAPIAI-87 — the ticket's latest ACCEPTED implementation output package, or nil when
      # Platform sent the explicit null a first specification carries. Read here and handed to
      # {Packet} as bounded read-only CONTEXT: it says what was actually shipped from the previous
      # specification, which a revision otherwise rewrites requirements without knowing.
      #
      # Validated by {#validate!}, so it is the explicit null or the exact closed block — never a
      # partial one a later stage would have to second-guess.
      #
      # It authorizes nothing. This lane creates no worktree, checks out no implementation branch
      # and pushes to no implementation repository, and the packet deliberately carries no clone
      # url so a provider has nothing to act on even if it tried.
      def previous_accepted_package = payload["previous_accepted_package"]

      # The SAME field as an AUTHORITY rather than as context, read through the one reader both
      # lanes use.
      #
      # `#previous_accepted_package` above hands the packet bounded read-only facts. This hands
      # preflight the object that can place those heads in the ticket's task environment, because
      # a workspace-grounded revision must analyse the code that was actually shipped rather than
      # a description of it. Reached for rather than reimplemented: a second continuation
      # implementation is how two lanes come to disagree about which head is current.
      #
      # Still a pure read. Nothing is verified and nothing is placed until a caller materializes.
      def previous_accepted_claim(env: ENV) = PreviousAcceptedPackage.read(payload, env: env)

      # The real provider profile the operator selected in Platform's Project Setup, or nil when
      # they selected the deterministic fixture — which this lane cannot use, and which
      # {Provider.resolve} must therefore refuse rather than quietly substitute a writer for.
      #
      # MVP-0028 remediation, defect 4. The specification lane LAUNCHES a provider, but until now
      # it resolved one from this runner's own YAML alone. A guided connection writes no YAML at
      # all, so a project whose operator had correctly selected a real provider in Project Setup
      # refused every generation with `generation_provider_unavailable`. The selection is
      # Platform's fact and had no channel to travel through; this is that channel, and it is the
      # same one the implementation lane has always used (`payload["executor"]`).
      #
      # {ImplementationProfile} compares the block with one of the exact approved hashes and raises
      # on anything else, so this reads a profile that Platform NAMED, not a command Platform may
      # run. That independent refusal is what keeps a Platform-supplied block from being an
      # arbitrary instruction — the same guarantee `Execution#guard_selected_executor!` relies on,
      # through the same authority, so the two lanes cannot disagree about what is launchable.
      #
      # Nil means "no real provider": either Platform sent no block at all, or it selected the
      # deterministic fixture, which is not a model-backed specification writer.
      # {#selected_provider_profile} is what tells those two apart for the operator.
      def selected_implementation_profile
        executor = section("specification_provider")["executor"].to_h
        return nil if executor.empty?

        ImplementationProfile.for(executor)
      end

      # What Platform says was selected, for a refusal that can name it. "fake" is the ordinary
      # reason the resolved profile is nil, and an operator reading "no provider is configured"
      # when they DID configure one deserves to be told which one they picked.
      def selected_provider_profile = section("specification_provider")["profile"].to_s

      # Every input the bundle recorded, as plain hashes with string keys. The runner reads
      # them but never trusts them as file paths or commands — they are evidence metadata.
      def inputs = Array(section("input_bundle")["inputs"]).map { |entry| entry.to_h }

      # `owner/repository` when Platform parsed them, else nil. Used as the lookup key for
      # the operator's local specification-repository checkout, so a runner connected to
      # two specification repositories can map each one.
      def target_slug
        return nil if target_owner.empty? || target_repository.empty?

        "#{target_owner}/#{target_repository}"
      end

      # How long this claim is good for, as Platform stated it. The generation loop checks
      # it so a long provider call cannot report success against a dead lease.
      def lease_expires_at = section("execution_policy")["lease_expires_at"].to_s
      def lease_renewal_seconds = section("execution_policy")["lease_renewal_seconds"].to_i

      # ------------------------------------------------------------------ MVP-0027

      # What this claim authorizes, read from the field Platform writes for exactly that
      # purpose. The runner branches on THIS rather than on `run.state`, so "what am I allowed
      # to do?" has one answer written by the control plane — and a runner build that does not
      # recognise the token stops instead of guessing.
      PUBLISH_ACTION = "publish_specification_package"
      GENERATE_ACTION = "generate_specification_package"

      def expected_runner_action = section("assignment_boundary")["expected_runner_action"].to_s
      def publication? = expected_runner_action == PUBLISH_ACTION

      # Generation is the DEFAULT for an empty action as well as for the explicit token: a
      # Platform old enough not to send the field at all can only be asking for generation, and
      # refusing it would break a runner against a Platform it used to work with. An action that
      # is present but unrecognised is a different case entirely — that is a newer Platform
      # asking for something this build does not implement, and guessing would be worse than
      # stopping.
      def generation? = expected_runner_action.empty? || expected_runner_action == GENERATE_ACTION

      # The publication decisions Platform made. The runner executes them; it never invents a
      # branch name, never chooses a base, and never decides whether a pull request is a draft.
      def publication_branch = publication["branch"].to_s
      def publication_base_branch = publication["base_branch"].to_s
      def publication_repository_url = publication["repository_url"].to_s
      def publication_slug = publication["slug"].to_s
      def create_pull_request? = publication["create_pull_request"] == true
      def draft_pull_request? = publication["pull_request_draft"] == true

      # MVP-0028 criterion 3 — the pull request Jira's `Spec PR` field already names for this
      # TICKET, or "" for a first publication. Platform checked it is a pull request on the
      # configured specification repository and stopped there, because it holds no GitHub
      # credentials; {ExistingPullRequest} is what asks GitHub whether it is usable and takes its
      # head branch. Absent for a first publication, which is what tells the runner to use
      # `publication_branch` instead.
      def existing_pull_request_url = publication["existing_pull_request_url"].to_s

      # The package Platform RECORDED at generation, with a digest per file. This is the
      # evidence the runner verifies its retained workspace against before it is allowed to
      # touch git — the whole point of publishing from Platform's record rather than from
      # whatever happens to be on the disk now.
      def generated_package_path = generated_package["path"].to_s

      # MAPIAI-62 — the OPAQUE identity of the Runner-owned workspace that generated this
      # package. It is the only address publication resolves: there is no path in the
      # assignment, no directory to search, and no checkout to fall back to. Platform stores it
      # beside the owning registered runner, so a runner that receives one has already been
      # proved by Platform to be the machine that created it.
      def generated_package_workspace_id = generated_package["workspace_id"].to_s

      def generated_files
        Array(generated_package["files"]).map do |file|
          entry = file.to_h
          { "path" => entry["path"].to_s, "sha256" => entry["sha256"].to_s }
        end
      end

      # Everything a publication needs, validated as a set BEFORE any git command runs. A
      # publication assignment missing one of these is a contract violation, and discovering it
      # halfway through — after a branch exists on a shared repository — is exactly what this
      # ordering prevents.
      PUBLICATION_REQUIRED = [
        [ %w[publication repository_url], "publication.repository_url" ],
        [ %w[publication branch], "publication.branch" ],
        [ %w[publication base_branch], "publication.base_branch" ],
        [ %w[generated_package path], "generated_package.path" ],
        # MAPIAI-62 — required, because there is no other way to find the package. A publication
        # assignment without it names work no runner can safely do, and discovering that after a
        # claim was burned is exactly what validating the set up front prevents.
        [ %w[generated_package workspace_id], "generated_package.workspace_id" ]
      ].freeze

      SHA256 = /\A[0-9a-f]{64}\z/

      def validate_publication!
        missing = PUBLICATION_REQUIRED.reject { |path, _| present?(payload.dig(*path)) }.map(&:last)
        raise Malformed, "publication assignment is missing required data: #{missing.join(', ')}" if missing.any?

        files = generated_files
        raise Malformed, "publication assignment names no generated file to publish" if files.empty?

        undigested = files.reject { |file| SHA256.match?(file["sha256"]) }.map { |file| file["path"] }
        raise Malformed, "publication assignment carries no usable digest for: #{undigested.join(', ')}" if
          undigested.any?

        self
      end

      # Prefer the command Platform sent, so the runner never invents an identifier — the
      # same rule the implementation lane follows for branch names.
      def release_command
        configured = section("assignment_boundary")["release_command"].to_s
        configured.strip.empty? ? "bin/platform runner release #{run_id}" : configured
      end

      private

      attr_reader :payload

      def target = section("specification_target")
      def publication = section("publication")
      def generated_package = section("generated_package")
      def section(name) = payload[name].to_h
      def present?(value) = !value.to_s.strip.empty?
    end
  end
end
