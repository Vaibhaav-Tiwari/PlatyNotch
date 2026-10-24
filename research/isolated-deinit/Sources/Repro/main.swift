// Usage: Repro <variant>. Each variant runs in its own process (an abort kills the process).
// Every release happens on the main thread. "outside a Task" = plain synchronous top-level code.
import Foundation
import ReproLib

@MainActor @inline(never) func releaseMainFoo() { _ = MainFoo() }
@MainActor @inline(never) func releaseMainPlain() { _ = MainPlain() }
@inline(never) func releaseCustomFoo() {
    if #available(macOS 15.4, *) { _ = CustomFoo() } else { print("SKIP: needs macOS 15.4"); exit(3) }
}
@MainActor @inline(never) func releaseWeaklyHeldMainFoo() {
    let h = Holder()
    do {
        let f = MainFoo()
        h.foo = f // weak reference: side table, like DragSubscription
    }
    _ = h
}

func finish(_ name: String) -> Never {
    print("RESULT \(name): survived, deinits=\(Counters.deinits)")
    exit(0)
}

let variant = CommandLine.arguments.dropFirst().first ?? "help"
print("variant \(variant), main thread: \(Thread.isMainThread)")

switch variant {
// a + d: released outside a Task, no TaskLocal bound.
case "a_noTask_noTaskLocal":
    releaseMainFoo()
    finish(variant)

// a + c: released outside a Task, inside a synchronous TaskLocal.withValue on the main thread.
case "a_noTask_taskLocal":
    ReproLocal.$marker.withValue(1) { releaseMainFoo() }
    finish(variant)

// Same, with a weak reference to the object (PlatyNotch's DragSubscription shape).
case "a_noTask_taskLocal_weakRef":
    ReproLocal.$marker.withValue(1) { releaseWeaklyHeldMainFoo() }
    finish(variant)

case "a_noTask_noTaskLocal_weakRef":
    releaseWeaklyHeldMainFoo()
    finish(variant)

// Control: plain (nonisolated) deinit, TaskLocal bound, outside a Task.
case "control_plainDeinit_noTask_taskLocal":
    ReproLocal.$marker.withValue(1) { releaseMainPlain() }
    finish(variant)

// b + d: released inside a @MainActor Task, no TaskLocal.
case "b_task_noTaskLocal":
    Task { @MainActor in
        releaseMainFoo()
        finish(variant)
    }
    dispatchMain()

// b + c: released inside a @MainActor Task, TaskLocal bound inside the task.
case "b_task_taskLocal":
    Task { @MainActor in
        ReproLocal.$marker.withValue(1) { releaseMainFoo() }
        finish(variant)
    }
    dispatchMain()

// b + c': TaskLocal bound synchronously outside, then a Task (inherits a copy) releases it.
case "b_task_inheritedTaskLocal":
    ReproLocal.$marker.withValue(1) {
        Task { @MainActor in
            releaseMainFoo()
            finish(variant)
        }
    }
    dispatchMain()

// e: custom global actor, released on the main thread outside a Task (not on that actor:
// the runtime enqueues the deinit as a job).
case "e_customActor_noTask_noTaskLocal", "e_customActor_noTask_taskLocal":
    if variant.hasSuffix("_taskLocal") && !variant.hasSuffix("noTaskLocal") {
        ReproLocal.$marker.withValue(1) { releaseCustomFoo() }
    } else {
        releaseCustomFoo()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(variant) }
    dispatchMain()

// e: custom global actor, released while running on that actor, TaskLocal bound in the task.
case "e_customActor_onActor_taskLocal":
    Task { @CustomActor in
        ReproLocal.$marker.withValue(1) { releaseCustomFoo() }
        DispatchQueue.main.async { finish(variant) }
    }
    dispatchMain()

default:
    print("unknown variant")
    exit(2)
}
