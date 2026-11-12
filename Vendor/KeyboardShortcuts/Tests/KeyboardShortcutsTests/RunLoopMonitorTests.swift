import XCTest
import AppKit
import Carbon.HIToolbox
@testable import KeyboardShortcuts

// Nested AppKit run loops can end Swift's async main drain before its test tasks finish.
nonisolated final class RunLoopMonitorTests: XCTestCase {
	@MainActor
	func testUnconsumedEventOrder() throws {
		// Warm up the event system, as the first `nextEvent` call in a process returns `nil` even when an event is queued.
		_ = NSApplication.shared.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: false)

		let firstKeyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
		let secondKeyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: UInt16(kVK_ANSI_B)))
		let mouseEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
		let keyUpEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
		let queuedEvents = [firstKeyEvent, secondKeyEvent, mouseEvent, keyUpEvent]
		var handledKeyCodes = [UInt16]()

		let monitor = RunLoopLocalEventMonitor(events: [.keyDown, .keyUp], runLoopMode: .eventTracking) { event in
			handledKeyCodes.append(event.keyCode)
			return event
		}
		monitor.start()
		defer {
			monitor.stop()
		}

		for event in queuedEvents.reversed() {
			NSApp.postEvent(event, atStart: true)
		}

		RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.2))
		monitor.stop()

		XCTAssertTrue(handledKeyCodes.starts(with: [UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_B)]))

		var remainingEvents = [NSEvent]()
		for _ in queuedEvents {
			if let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: true) {
				remainingEvents.append(event)
			}
		}

		XCTAssertEqual(remainingEvents.map(\.type), queuedEvents.map(\.type))
		XCTAssertEqual(remainingEvents.filter(\.isKeyEvent).map(\.keyCode), queuedEvents.filter(\.isKeyEvent).map(\.keyCode))
	}

	@MainActor
	func testMatchingEventsLeaveOthersQueued() throws {
		// Warm up the event system, as the first `nextEvent` call in a process returns `nil` even when an event is queued.
		_ = NSApplication.shared.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: false)

		let keyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
		let mouseEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

		var handledKeyCodes = [UInt16]()

		let monitor = RunLoopLocalEventMonitor(events: [.keyDown], runLoopMode: .eventTracking) { event in
			handledKeyCodes.append(event.keyCode)
			// Consume the event.
			return nil
		}

		monitor.start()
		defer {
			monitor.stop()
		}

		NSApp.postEvent(mouseEvent, atStart: false)
		NSApp.postEvent(keyEvent, atStart: false)
		RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.2))

		XCTAssertTrue(handledKeyCodes.isEmpty)

		// The non-matching mouse event was left untouched in the queue, so it is never dequeued or re-posted.
		let remainingEvent = NSApp.nextEvent(matching: .any, until: nil, inMode: .eventTracking, dequeue: true)
		XCTAssertEqual(remainingEvent?.type, .mouseMoved)

		RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.2))

		// The matching key event was handled and consumed after the blocking mouse event was removed.
		XCTAssertEqual(handledKeyCodes, [UInt16(kVK_ANSI_A)])
		XCTAssertNil(NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .eventTracking, dequeue: true))
	}

}
