# Native Automatic Cyclic I/O Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace public manual port transfer with native process images and exact-typed whole/member connections throughout the maintained toolchain.

**Architecture:** Ports own typed images; a runtime-only capability handles sample transport. A prepared component plan resolves nested services and assembles matching endpoint mappings around the existing updateHook(). OCL declares mappings and validates them before activation.

**Tech Stack:** C++20, RTT/OCL, Boost.Test, CMake/CTest, OroGen Ruby templates, native OPC UA and HTTP plugins.

## Global Constraints

- Keep all changes in coordinated `feat/automatic-cyclic-io` worktrees; do not merge or release.
- Keep the canonical install prefix unchanged; use this worktree's `install/`.
- One TaskContext component model; no public read/write or legacy/manual mode.
- All combinations of matching whole/member endpoints, including nested services and fixed arrays.
- No allocation, reflection construction, name traversal or unbounded queue draining in new fixed-type cyclic work.
- Exact type and array shape validation; one writer per destination region.
- Lifecycle and storage lifetime checks cover runtime errors, exceptions, stops, service removal and port destruction.
- Network ingress stages data; observers use committed snapshots.

### Task 1: Establish isolated baseline and owned port images

**Files:** RTT `rtt/InputPort.hpp`, `rtt/OutputPort.hpp`, `rtt/base/{InputPortInterface,OutputPortInterface}.{hpp,cpp}`, `rtt/internal/PortDataAccess.hpp`, `rtt/internal/InputPortSource.hpp`, `tests/cyclic_ports_test.cpp`, `tests/CMakeLists.txt`.

**Interfaces:** Input `const T& data() const`; output `T& data()` and const overload. Runtime capability `PortDataAccess` supplies typed/generic receive, publish, image-source access, image refresh/commit and observation. Existing low-level channel tests use this explicitly internal capability; component-facing samples use images.

- [ ] Build/test the unchanged feature checkout and retain baseline logs.
- [ ] Add tests that fail before implementation: input image constness; output mutation does not publish; runtime commit updates committed snapshot; runtime acquisition changes input image; script read/write absent.
- [ ] Implement owned stable images and runtime-only transfer dispatch; remove public consuming/publishing APIs.
- [ ] Migrate RTT internal consumers and channel tests to the correct image or transport layer. Run `cmake --build build/rtt -j 3` and `ctest --test-dir build/rtt --output-on-failure`.
- [ ] Review and commit the port ownership change.

### Task 2: Native cyclic execution and typed mappings

**Files:** RTT new `rtt/internal/CyclicDataFlow.{hpp,cpp}`, `rtt/TaskContext.{hpp,cpp}`, `rtt/ExecutionEngine.cpp`, `rtt/Service.{hpp,cpp}`, `rtt/DataFlowInterface.{hpp,cpp}`, `rtt/base/PortInterface.{hpp,cpp}`, `tests/cyclic_dataflow_test.cpp`.

**Interfaces:** C++ `connectMembers(OutputPortInterface&, string sourcePath, InputPortInterface&, string destinationPath)`; empty path is whole value. TaskContext prepares/finalizes a flat plan and its engine refreshes/commits it. Coordinate exact declarations with Task 1 before editing.

- [ ] Add failing tests using real TaskContexts and sequential/slave execution: updateHook reads current input and output remains uncommitted until hook completion; no publication after throw/error.
- [ ] Add literal-value mapping tests for whole/whole, scalar/field, field/scalar, field/field, selected structs, arrays, and multiple sources into one image.
- [ ] Add negative tests for missing members, conversions, index syntax/bounds, unequal array lengths, overlapping destinations, and active mutation.
- [ ] Build source subscriptions and assignment actions during finalization; recurse over service interfaces only there.
- [ ] Integrate lifecycle-safe preparation/publication and invalidate before topology destruction.
- [ ] Validate zero fixed-type allocations over repeated cycles and run RTT tests; review and commit.

### Task 3: OCL deployment and component migration

**Files:** OCL `deployment/DeploymentComponent.{hpp,cpp}`, deployment tests/fixtures, `helloworld/`, `lua/`, `reporting/`, `timer/`, `taskbrowser/` consumers.

**Interfaces:** `.ops` operations `connectPort(string,string)`, `connectMember(string,string,string,string)`, `finalizeConnections()` backed by Task 2. Resolve service-qualified port names separately from data member paths.

- [ ] Add a failing deployment fixture with producer `{y,z}`, consumer `{x,y}`, and second scalar source. Assert consumer sees exact mapped values after native cycles without calling read/write.
- [ ] Add whole/selected-struct and nested-service script cases plus invalid graph failure cases.
- [ ] Implement declaration/finalization operations and migrate bundled components to owned images.
- [ ] Remove manual Lua/script APIs; reporting observes snapshots; migrate timer events explicitly without pretending latest-value state preserves every event.
- [ ] Build OCL against private installed RTT and run all enabled deployment/component tests. Review and commit.

### Task 4: Transports and generators

**Files:** `rtt_opcua` port bridge/remote port consumers and tests; `rtt_http` server sample endpoint/observation and tests; `rtt_typelib` marshaling; OroGen task/typekit templates and tests.

**Interfaces:** Components use port images. Runtime ingress/egress uses the internal capability and synchronized staging. Lifecycle-state observation is a runtime facility, not a restored public write method.

- [ ] Add/adjust failing transport tests proving ingress does not mutate an active input image and output observation sees committed values.
- [ ] Migrate generic and typed transport consumers, retaining capacity/failure handling.
- [ ] Generate and build a sample component whose hook uses only images; migrate generator state-export semantics explicitly.
- [ ] Build every affected package into the private prefix and run their tests. Review and commit package changes.

### Task 5: Validation, documentation and review

**Files:** Root `tests/cyclic-dataflow/`, validation scripts, documentation, source selections for review builds; package migration guidance and release notes.

- [ ] Run full native RTT, OCL, transport and generator checks, plus installed-prefix consumer validation.
- [ ] Run focused sanitizer/concurrent snapshot tests and allocation probes; fix every detected correctness issue.
- [ ] Measure cyclic timing against the retained baseline for fixed sample sizes and increasing mapping/fan-out counts. Record target, build flags, distributions and measurement limitations.
- [ ] Document endpoint syntax, process-image ownership, service paths, startup/default/freshness rules, lifecycle/transport boundaries and breaking migration.
- [ ] Audit remaining public/manual APIs, inspect every package diff and obtain independent review.
- [ ] Commit/push feature branches and prepare draft PRs with complete validation evidence if appropriate. Keep all PRs unmerged; pending CI/platform validation remains an explicit gate. Do not port to OptimalCNC yet.
