# frozen_string_literal: true

require_relative "test_helper"
require "json"

# MAPIAI-97 — the adversarial status/URL matrix at the Runner boundary.
#
# Three things are proved here. First, that a REAL project-owned document — which carries slots,
# port blocks, Compose project names and repository state — is accepted and reduced to the closed
# four-field shape, with none of that operational detail surviving onto the wire. Second, that the
# COMPLETE project-owned service list is validated before any service is classified as internal:
# a service with no browser url is still part of the application whose readiness this document
# claims. Third, that every unsafe variant refuses the COMPLETE result rather than dropping one
# entry, because a page that silently shows three of four services lies about what is running.
class PreviewStatusTest < Minitest::Test
  TASK = "MAPIAI-97-provide-live-task-preview-urls-for-human-approval"

  def service(name: "dashboard", url: "http://127.0.0.1:5173", state: "running", health: "healthy", **extra)
    { "service" => name, "state" => state, "health" => health, "url" => url }.merge(extra)
  end

  # An internal service is the same document with no browser url. Nothing else about it is relaxed.
  def internal(name: "database", **overrides) = service(name: name, url: nil, **overrides)

  def without(key, **overrides) = internal(**overrides).tap { |entry| entry.delete(key) }

  def document(services: [ service ], primary: "http://127.0.0.1:5173", task: TASK, state: "RUNNING", **extra)
    { "task_id" => task, "state" => state, "primary_url" => primary, "services" => services }.merge(extra)
  end

  def project(document) = SpecrelayRunner::PreviewStatus.project(JSON.generate(document), task_id: TASK)

  # Every refusal is checked for the same two things: the stated reason, and that NO partial
  # service list escaped with it.
  def refuses(document, expected)
    result = project(document)
    refute result.ok?, "expected a refusal"
    assert_includes result.reason, expected
    assert_nil result.document
    assert_equal [], result.services
    result
  end

  def test_a_real_project_document_is_reduced_to_the_closed_shape
    real = document(
      services: [ service(name: "dashboard", url: "http://127.0.0.1:5173", host_port: 5173),
                  service(name: "crm", url: "http://127.0.0.1:5174", health: "none", host_port: 5174) ],
      branch: TASK, slot: 4, port_block: [ 5100, 5199 ], compose_project: "srt-abc",
      repositories: [ { "worktree_path" => "/Users/someone/dev/x", "head_commit" => "a" * 40 } ],
      development_data_modes: { "platform.postgres" => "schema_only" }
    )

    result = project(real)

    assert result.ok?, result.reason
    assert_equal %w[contract_version task_id state primary_url services], result.document.keys
    assert_equal %w[service state health url], result.document["services"].first.keys
    # Nothing operational survives the projection.
    dumped = JSON.generate(result.document)
    %w[worktree_path compose_project port_block host_port repositories slot].each do |leaked|
      refute_includes dumped, leaked
    end
  end

  # F5 — the complete raw list is judged BEFORE anything is classified as internal. Every case
  # here also carries one perfectly good openable service, so a projection that filtered first
  # would return a green result and hide the broken service entirely.
  #
  # Every case is evaluated before asserting, so the failure names ALL of them at once rather
  # than stopping at the first.
  def f5_cases
    {
      "a scalar instead of an object" => [ [ service, "database" ], "is not an object" ],
      "no url key at all" => [ [ service, without("url") ], "is missing \"url\"" ],
      "no name" => [ [ service, without("service") ], "is missing \"service\"" ],
      "no state" => [ [ service, without("state") ], "is missing \"state\"" ],
      "no health" => [ [ service, without("health") ], "is missing \"health\"" ],
      "an exited internal service" => [ [ service, internal(state: "exited") ], "reports \"exited\", not running" ],
      "a starting internal service" => [ [ service, internal(state: "starting") ], "reports \"starting\", not running" ],
      "an unhealthy internal service" => [ [ service, internal(health: "unhealthy") ], "reports the health \"unhealthy\"" ],
      "an unknown internal health" => [ [ service, internal(health: "degraded") ], "reports the health \"degraded\"" ],
      "an internal duplicate of an openable name" => [ [ service, internal(name: "dashboard") ], "twice" ],
      "two internal names differing only in case" =>
        [ [ service, internal(name: "cache"), internal(name: "CACHE") ], "twice" ],
      "an array url" => [ [ service, internal(url: [ "http://127.0.0.1:5174" ]) ], "is not a plain value" ],
      "a hash url" => [ [ service, internal(url: { "href" => "http://127.0.0.1:5174" }) ], "is not a plain value" ]
    }
  end

  def test_no_malformed_or_unhealthy_service_can_hide_by_having_no_url
    hidden = f5_cases.reject do |_name, (services, expected)|
      result = project(document(services: services))
      !result.ok? && result.reason.to_s.include?(expected) && result.document.nil?
    end

    assert_equal [], hidden.keys,
                 "the projection accepted, mis-stated or partially returned these broken services"
  end

  # The project's own convention for "this service has no browser url" is an explicit null or an
  # empty string. Both mean internal; neither becomes a link.
  def test_a_coherent_internal_service_is_accepted_and_absent_from_the_wire
    [ nil, "" ].each do |url|
      result = project(document(services: [ service, internal(url: url, host_port: 5432) ]))

      assert result.ok?, "#{url.inspect}: #{result.reason}"
      assert_equal [ "dashboard" ], result.services.map { |entry| entry["service"] }
      dumped = JSON.generate(result.document)
      refute_includes dumped, "database"
      refute_includes dumped, "host_port"
    end
  end

  def test_a_project_with_only_internal_services_is_unavailable
    refuses(document(services: [ internal, internal(name: "queue") ], primary: ""), "no service to open")
  end

  def test_an_unsafe_openable_url_refuses_a_document_whose_other_services_are_coherent
    refuses(document(services: [ service, internal, service(name: "crm", url: "http://10.0.0.5:5174") ]),
            "is not on 127.0.0.1")
  end

  def test_a_document_for_another_task_is_refused
    refuses(document(task: "SOME-OTHER-TASK"), "not \"#{TASK}\"")
  end

  def test_a_non_running_environment_is_refused
    refuses(document(state: "STOPPED"), "not RUNNING")
  end

  def test_unparseable_and_oversized_documents_are_refused
    unparseable = SpecrelayRunner::PreviewStatus.project("{ not json", task_id: TASK)
    refute unparseable.ok?
    assert_includes unparseable.reason, "not valid JSON"

    oversized = SpecrelayRunner::PreviewStatus.project("\"#{'x' * (512 * 1024 + 8)}\"", task_id: TASK)
    refute oversized.ok?
    assert_includes oversized.reason, "larger than"
  end

  def test_an_empty_service_list_is_refused
    refuses(document(services: []), "no service to open")
  end

  def test_more_than_twenty_services_are_refused
    many = Array.new(21) { |index| service(name: "s#{index}", url: "http://127.0.0.1:#{5000 + index}") }
    refuses(document(services: many, primary: "http://127.0.0.1:5000"), "more than 20 services")
  end

  def test_twenty_services_are_accepted
    many = Array.new(20) { |index| service(name: "s#{index}", url: "http://127.0.0.1:#{5000 + index}") }
    result = project(document(services: many, primary: "http://127.0.0.1:5000"))

    assert result.ok?, result.reason
    assert_equal 20, result.services.length
  end

  def test_duplicate_service_names_and_urls_are_refused
    refuses(document(services: [ service, service(url: "http://127.0.0.1:5174") ]), "twice")
    refuses(document(services: [ service, service(name: "crm") ]), "twice")
  end

  def test_an_unsafe_service_name_is_refused
    refuses(document(services: [ service(name: "dash board/../x") ]), "not a safe name")
    refuses(document(services: [ service(name: "d" * 65) ]), "longer than 64 bytes")
  end

  def test_an_incoherent_service_state_or_health_is_refused
    refuses(document(services: [ service(state: "starting") ]), "not running")
    refuses(document(services: [ service(health: "unhealthy") ]), "reports the health")
  end

  def test_every_unsafe_url_variant_refuses_the_whole_result
    {
      "file:///etc/passwd" => "does not use http or https",
      "ftp://127.0.0.1:5173" => "does not use http or https",
      "http://localhost:5173" => "is not on 127.0.0.1",
      "http://127.0.0.2:5173" => "is not on 127.0.0.1",
      "http://[::1]:5173" => "is not on 127.0.0.1",
      "http://evil.example.com:5173" => "is not on 127.0.0.1",
      "http://user:pass@127.0.0.1:5173" => "carries credentials",
      "http://127.0.0.1:5173?a=1" => "carries a query or fragment",
      "http://127.0.0.1:5173#f" => "carries a query or fragment",
      "http://127.0.0.1" => "names no explicit port",
      "http://127.0.0.1:80" => "not on an ordinary port",
      "http://127.0.0.1:70000" => "not on an ordinary port",
      "http://127.0.0.1:5173/admin" => "names a path"
    }.each do |url, expected|
      refuses(document(services: [ service(url: url) ], primary: url), expected)
    end
  end

  def test_an_over_long_url_is_refused
    long = "http://127.0.0.1:5173/#{'a' * 2100}"
    refuses(document(services: [ service(url: long) ], primary: long), "longer than 2048 bytes")
  end

  def test_a_missing_or_foreign_primary_url_is_refused
    refuses(document(primary: ""), "no primary url")
    refuses(document(primary: "http://127.0.0.1:9999"), "not one of the reported services")
  end
end
