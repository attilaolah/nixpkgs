{
  lib,
  cargo,
  fetchFromGitHub,
  fetchurl,
  linkFarm,
  python3,
  python3Packages,
  rustPlatform,
  rustc,
  stdenv,
  unzip,
  versionCheckHook,
  ast-grep,
  difftastic,
  scc,
  git,
  pkg-config,
  oniguruma,
  sqlite,
  writableTmpDirAsHomeHook,
}:

let
  # mcp 2.3.0's test suite imports logfire. logfire 4.41.0 caps
  # OpenTelemetry below 1.45.0, while nixpkgs ships 1.45.2; relax those
  # test-only bounds locally so mcp's checks can run.
  pythonPackages = python3Packages.overrideScope (
    final: prev: {
      logfire = prev.logfire.overridePythonAttrs (old: {
        pythonRelaxDeps = [
          "opentelemetry-exporter-otlp-proto-http"
          "opentelemetry-sdk"
        ];
      });
    }
  );

  dependencies =
    with pythonPackages;
    [
      anthropic
      ast-grep-cli
      click
      datasets
      fakeredis
      fastapi
      fastembed
      filelock
      h2
      httpx
      huggingface-hub
      jinja2
      litellm
      magika
      mcp
      numpy
      onnxruntime
      openai
      openpyxl
      opentelemetry-api
      opentelemetry-exporter-http-transport
      opentelemetry-exporter-otlp-common
      opentelemetry-exporter-otlp-proto-http
      opentelemetry-sdk
      orjson
      pillow
      pydantic
      python-socks
      pyyaml
      rapidocr
      rich
      scikit-learn
      sentence-transformers
      sentencepiece
      sqlite-vec
      starlette
      tiktoken
      tomlkit
      torch
      trafilatura
      transformers
      tree-sitter
      tree-sitter-language-pack
      truststore
      uvicorn
      watchdog
      websockets
      xlrd
      zstandard
    ]
    # Upstream gates hf-xet on x86_64/aarch64 (and their AMD64/arm64 aliases).
    ++ lib.optionals (stdenv.hostPlatform.isx86_64 || stdenv.hostPlatform.isAarch64) [
      pythonPackages.hf-xet
    ];

  bundledTools = [
    ast-grep
    difftastic
    scc
  ];

  tiktokenEncodings = linkFarm "tiktoken-encodings" [
    {
      name = "0ea1e91bbb3a60f729a8dc8f777fd2fc07cd8df4";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/r50k_base.tiktoken";
        hash = "sha256-MGzSfwPBpxTspxCOA9ZrfcBCq+jCWLRMGZp+2YON2TA=";
      };
    }
    {
      name = "ec7223a39ce59f226a68acc30dc1af2788490e15";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/p50k_base.tiktoken";
        hash = "sha256-lLXKff9NAHZ7wlb90bJ+Wxc2HXuKX5aFR/nyPrcNIGk=";
      };
    }
    {
      name = "9b5ad71b2ce5302211f9c61530b329a4922fc6a4";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken";
        hash = "sha256-Ijkht27pm96ZW3/3OFE+7xAPtR0YyTWXoRO8/+hlsqc=";
      };
    }
    {
      name = "fb374d419588a4632f3f557e76b4b70aebbca790";
      path = fetchurl {
        url = "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken";
        hash = "sha256-RGqVOMtsNI41FhINfAiwn1fDZJXirP/+WaW/iwz7Gi0=";
      };
    }
  ];
in
pythonPackages.buildPythonApplication (finalAttrs: {
  pname = "headroom";
  version = "0.43.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "headroomlabs-ai";
    repo = "headroom";
    tag = "v${finalAttrs.version}";
    hash = "sha256-lZNB0v5nheQyiZF4EoRgqqsjmGjg7n98OgiWQCZejXQ=";
  };

  patches = [
    ./restore-cli-main-before-offline-check.patch
    ./preserve-sandbox-proxy-environment.patch
    # Keep three upstream tests runnable in the Nix sandbox: preserve the
    # inherited PYTHONPATH, avoid the missing /usr/bin/env, and skip chmod of
    # setuid/setgid modes when the sandbox rejects them.
    ./fix-sandbox-tests.patch
  ];

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-NkbMkyCc2i64nhKBE7ZdSAjefvhQac+InWDjlbQg474=";
  };

  build-system = [
    cargo
    rustc
    rustPlatform.cargoSetupHook
    rustPlatform.maturinBuildHook
  ];

  inherit dependencies;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    oniguruma
    sqlite
  ];

  makeWrapperArgs = [
    # Preserve PYTHONPATH because proxy startup re-execs `python -m headroom.cli`.
    "--prefix"
    "PYTHONPATH"
    ":"
    "${placeholder "out"}/${python3.sitePackages}:${pythonPackages.makePythonPath dependencies}"

    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath bundledTools)

    # Bundle Tiktoken encodings instead of lazily downloading them.
    "--set"
    "TIKTOKEN_CACHE_DIR"
    tiktokenEncodings
  ];

  pythonImportsCheck = [ "headroom" ];

  # Counts refer to test functions (some are parametrized).
  disabledTests = [
    # These tests cover service/process management or platform behavior untestable in the sandbox.

    # tests/test_cli/test_mcp_reconcile.py: 1/18 disabled
    "test_ordinary_install_does_not_adopt_serena"

    # tests/test_cli_proxy_improvements.py: 2/58 disabled
    "test_ensure_proxy_dependencies_exits_when_fastapi_missing"
    "test_proxy_command_exits_when_mcp_missing"

    # tests/test_copilot_auth.py: 3/105 disabled
    "test_device_authorization_uses_form_encoded_request"
    "test_device_poll_uses_form_encoded_request"
    "test_exchange_token_sync_raises_for_http_error"

    # tests/test_graph.py: 1/6 disabled
    # /build is ignored by the watcher, so the main.py event never schedules a reindex.
    "test_code_graph_watcher_init_start_stop_and_event_filtering"

    # tests/test_hard_watchdog.py: 3/6 disabled
    # These subprocesses replace the environment, losing Nix's PYTHONPATH.
    "test_healthy_process_is_never_shot"
    "test_seized_gil_is_dumped_and_exited"
    "test_swapped_stderr_does_not_kill_the_heartbeat"

    # tests/test_install/test_native_installers.py: 2/10 disabled
    "test_bash_native_installer_supports_persistent_docker_lifecycle"
    "test_bash_native_wrapper_supports_opencode"

    # tests/test_install/test_runtime.py: 1/56 disabled
    "test_runtime_start_lock_blocks_another_process"

    # tests/test_install/test_supervisors.py: 1/59 disabled
    "test_install_supervisor_darwin_windows_and_unsupported"

    # tests/test_package_init_lazy.py: 1/13 disabled
    "test_dynamic_detector_import_skips_optional_ml_dependencies"

    # tests/test_proxy_scalability.py: 1/18 disabled
    "test_run_server_uses_selector_loop_on_windows"

    # tests/test_stateless_no_disk.py: 1/14 disabled
    # CliRunner enters proxy dependency startup before observing the environment flag.
    "test_cli_stateless_flag_exports_env_for_children"

    # The following tests require Hugging Face models or datasets unavailable in the sandbox.

    # tests/test_evals/test_html_oss_benchmarks.py: 5/12 disabled
    "test_benchmark_loads"
    "test_compression_achieved"
    "test_extraction_f1_full"
    "test_extraction_f1_medium"
    "test_extraction_f1_quick"

    # tests/test_memory/test_embedder_thread_cap.py: 1/9 disabled
    "test_cpu_embed_workers_are_thread_capped"

    # tests/test_memory/test_embedder_mps_serialization.py: 1/4 disabled
    "test_cpu_uses_dedicated_thread_capped_executor"

    # tests/test_memory/test_hierarchical.py: 4/43 disabled
    # test_embed_batch also matches test_embed_batch_uses_batched_onnx_inference.
    "test_embed_batch"
    "test_embed_single"
    "test_similar_texts_have_high_similarity"

    # tests/test_memory_bridge.py: 1/43 disabled
    "test_import_export_preserves_facts"

    # tests/test_relevance.py: 4/35 disabled
    "test_batch_efficiency"
    "test_hybrid_scoring"
    "test_paraphrase_match"
    "test_semantic_match"

    # tests/gateway/test_compress_turn_seam.py: 1/9 disabled
    # The route is claimed by the generic proxy when the optional gateway contract is disabled.
    "test_contract_disabled_by_env"
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    # tests/test_cli/test_wrap_persistent.py: 4/62 disabled
    # These fixtures omit runtime_kind, causing persistent proxy recovery to fail on Darwin.
    "test_ensure_proxy_recovers_matching_persistent_deployment"
    "test_ensure_proxy_recovers_persistent_deployment_when_socket_is_bound"
    "test_recover_persistent_proxy_reuses_healthy_deployment"
    "test_recover_persistent_proxy_warns_for_task_deployment"

    # tests/test_content_router_ml_stage_deadline.py: 4/16 disabled
    # Sub-second timing assertions are flaky with Darwin sandbox scheduling latency.
    "test_non_ml_prework_does_not_consume_the_ml_budget"
    "test_cold_remote_call_is_bounded_as_a_whole_by_the_ml_budget"
    "test_saturated_remote_calls_fail_open_without_queueing_their_payloads"
    "test_slow_drip_response_is_cut_off_at_an_absolute_deadline"

    # tests/test_content_router_single_item_deadline.py: 1/4 disabled
    # This test is also sensitive to Darwin sandbox scheduling latency.
    "test_single_cache_miss_deadline_starts_before_kompress_load"

    # tests/test_proxy_uds.py: 11/24 disabled
    # Darwin has a 104-byte UNIX socket path limit, which Nix's pytest temporary-directory paths exceed.
    "test_prepare_accepts_a_sticky_world_writable_parent"
    "test_prepare_clears_a_stale_socket"
    "test_prepare_creates_parent_owner_only"
    "test_prepare_never_deletes_a_regular_file"
    "test_prepare_only_chmods_directories_it_creates"
    "test_prepare_preserves_an_existing_parents_mode"
    "test_prepare_refuses_a_live_socket"
    "test_prepare_refuses_a_world_writable_existing_parent"
    "test_remove_uds_path_is_socket_only"
    "test_run_server_binds_the_socket_instead_of_a_port"
    "test_run_server_removes_the_socket_on_exit"
  ];

  nativeCheckInputs =
    with pythonPackages;
    [
      cryptography
      git
      hnswlib
      httpx2
      langchain-ollama
      ollama
      pytest-asyncio
      pytest-cov-stub
      pytestCheckHook
      respx
      socksio
      unzip
      versionCheckHook
      xlwt
      writableTmpDirAsHomeHook
    ]
    ++ bundledTools;

  versionCheckProgram = "${placeholder "out"}/bin/headroom";

  preCheck = ''
    # Fail fast for optional Hugging Face models, which cannot be downloaded in the test sandbox.
    export HF_HUB_OFFLINE=1
    export TRANSFORMERS_OFFLINE=1

    # Tiktoken lazily downloads its OpenAI encoding files. Use Nix-fetched copies in the test sandbox.
    export TIKTOKEN_CACHE_DIR=${tiktokenEncodings}

    # The upstream health probe and SSRF guard cannot reach the mock upstream hosts in the test sandbox.
    export HEADROOM_SKIP_UPSTREAM_CHECK=1
    export HEADROOM_ALLOWED_BASE_URLS=httpbin.org,api.deepseek.com,opencode.ai,api.githubcopilot.com

    # Use LiteLLM's bundled price map; the test sandbox has no network access.
    export LITELLM_LOCAL_MODEL_COST_MAP=True

    # The source package is needed by tests that load files directly by path.
    # Extract only maturin's platform-specific native module from the wheel.
    unzip -j "$dist"/*.whl 'headroom/_core.*' -d headroom
  '';

  meta = {
    description = "Context optimization layer for LLM applications";
    homepage = "https://github.com/headroomlabs-ai/headroom";
    license = lib.licenses.asl20;
    mainProgram = "headroom";
    maintainers = with lib.maintainers; [ attila ];
  };
})
