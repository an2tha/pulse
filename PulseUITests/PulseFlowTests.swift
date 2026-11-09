import XCTest

@MainActor
final class PulseFlowTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PULSE_TEST_JOURNAL"] = UUID().uuidString
        app.launchEnvironment["PULSE_SKIP_ONBOARDING"] = "1"
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testForecastOverviewJumpsToNoonOnTheRuler() throws {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["Planning options"].tap()
        app.buttons["Edit time blocks and forecast"].tap()
        let overview = app.sliders["forecast-day-navigator"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        let day = try XCTUnwrap(Calendar.current.dateInterval(of: .day, for: .now))
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day.start))
        let fraction = (noon.addingTimeInterval(600).timeIntervalSince(day.start)) / day.duration
        overview.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.25)).tap()
        let label = "Browse forecast hours, " + noon.formatted(date: .omitted, time: .shortened)
        let reachedNoon = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", label), object: overview)
        XCTAssertEqual(XCTWaiter.wait(for: [reachedNoon], timeout: 5), .completed)
    }

    func testNewTaskWaitsInDrawerAndCanBeScheduledByTap() {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["New task"].tap()
        let name = app.textFields["Task name"]
        name.tap()
        name.typeText("Sketch the mantle")
        app.buttons["Save"].tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'day-drawer-task-' AND label == %@", "Schedule Sketch the mantle")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let drawer = app.buttons["day-task-drawer"]
        drawer.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        drawer.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Task timing"].waitForExistence(timeout: 5))
    }

    func testDrawAndResizeTomorrowFocusBlock() {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()

        app.buttons["week-day-tools"].tap()
        let hours = app.buttons["timeline-hours-toggle"]
        XCTAssertTrue(hours.waitForExistence(timeout: 5))
        XCTAssertEqual(hours.label, "Show hours")
        hours.tap()
        XCTAssertEqual(hours.label, "Hide hours")
        hours.tap()
        let draw = app.buttons["timeline-draw-toggle"]
        XCTAssertEqual(draw.label, "New block")
        draw.tap()
        let surface = app.descendants(matching: .any)["timeline-draw-surface"]
        let overview = app.sliders["forecast-day-navigator"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-timeline-block"].isEnabled, "A suggested range can be saved immediately")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func chartPoint(_ fraction: CGFloat) -> XCUICoordinate {
            origin.withOffset(CGVector(dx: overview.frame.minX + overview.frame.width * fraction,
                                       dy: surface.frame.midY))
        }
        chartPoint(0.2).press(forDuration: 0.12, thenDragTo: chartPoint(0.5))
        let review = app.buttons["review-timeline-block"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        app.buttons["save-timeline-block"].tap()

        if hours.label == "Show hours" { hours.tap() }
        let block = app.buttons.matching(NSPredicate(format: "label == %@", "Focus time")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        draw.tap()
        block.tap()
        let end = app.descendants(matching: .any)["timeline-range-end"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let endTime = app.datePickers["timeline-block-end-time"]
        let initialEnd = endTime.value as? String
        let handle = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.press(forDuration: 0.12, thenDragTo: handle.withOffset(CGVector(dx: overview.frame.width * 0.17, dy: 0)))
        let savedEnd = endTime.value as? String
        XCTAssertNotNil(savedEnd)
        XCTAssertNotEqual(savedEnd, initialEnd)
        review.tap()
        XCTAssertTrue(app.navigationBars["Resize block"].exists)
        app.buttons["save-timeline-block"].tap()
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
        app.buttons["week-day-tools"].tap()
        if hours.label == "Show hours" { hours.tap() }
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        draw.tap()
        block.tap()
        XCTAssertEqual(endTime.value as? String, savedEnd)
    }

    func testWeekDrawerDragCrossesDayChipAndDropsOntoExactMinuteWithoutLifting() throws {
        let app = launch()
        let title = "Water the ivy"
        app.buttons["tab-Plan"].tap()
        app.buttons["New task"].tap()
        app.textFields["Task name"].tap()
        app.textFields["Task name"].typeText(title)
        app.buttons["Save"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now)))
        let stamp = Int(day.timeIntervalSince1970)
        app.buttons["plan-day-\(stamp)"].tap()
        XCTAssertTrue(app.buttons["week-back-to-overview"].waitForExistence(timeout: 5))
        let drawer = app.buttons["day-task-drawer"]
        XCTAssertTrue(drawer.isHittable)
        drawer.tap()
        let source = app.buttons["Schedule " + title]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let targetChip = app.buttons["plan-day-\(stamp)"]
        // Use the destination's settled clock geometry with the drawer already expanded.
        targetChip.tap()
        let hour = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        func clock(_ time: Date) -> XCUIElement {
            app.descendants(matching: .any)["day-hour-\(Int(time.timeIntervalSince1970))"].firstMatch
        }
        let label = clock(hour)
        let next = clock(hour.addingTimeInterval(3600))
        XCTAssertTrue(label.isHittable && next.isHittable)
        let height = next.frame.minY - label.frame.minY
        XCTAssertGreaterThan(height, 44)
        let y = label.frame.minY - 8 + height * 17.5 / 60
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let previous = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        app.buttons["plan-day-\(Int(previous.timeIntervalSince1970))"].tap()
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
        XCTAssertTrue(source.isHittable && targetChip.isHittable)

        // At 50 points per second the finger spends at least 880 ms inside the 44-point chip.
        // Keep the same vertical path from the source row across the chip to the destination.
        let x = targetChip.frame.midX
        let lift = origin.withOffset(CGVector(dx: x, dy: source.frame.midY))
        let target = origin.withOffset(CGVector(dx: x, dy: y))
        XCTAssertTrue(source.frame.contains(CGPoint(x: x, y: source.frame.midY)))
        XCTAssertLessThan(y, targetChip.frame.minY)
        XCTAssertGreaterThan(source.frame.midY, targetChip.frame.maxY)
        lift.press(forDuration: 0.8, thenDragTo: target, withVelocity: XCUIGestureVelocity(rawValue: 50), thenHoldForDuration: 0.1)
        let scheduled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                          "week-task-\(stamp)-", title)).firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        let expected = hour.addingTimeInterval(17 * 60).formatted(date: .omitted, time: .shortened)
        XCTAssertTrue((scheduled.value as? String)?.hasPrefix(expected) == true)
        XCTAssertFalse(source.exists)
        XCTAssertTrue(drawer.isHittable)
        scheduled.press(forDuration: 0.8, thenDragTo: drawer)
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(scheduled.waitForNonExistence(timeout: 8))
    }

    func testResizeTomorrowTaskPersistsItsNewEnd() throws {
        let app = launch()
        let title = "Review the sample"
        app.buttons["Quick add"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes tomorrow")
        app.buttons["Add to inbox"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()

        let day = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)))
        let prefix = "week-task-\(Int(day.timeIntervalSince1970))-"
        let task = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix, title)).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 8))
        let uuid = String(task.identifier.dropFirst(prefix.count))
        let handle = app.descendants(matching: .any)["timeline-duration-" + uuid].firstMatch
        if !handle.isHittable { app.swipeUp() }
        XCTAssertTrue(handle.isHittable)
        XCTAssertEqual(handle.value as? String, "5 minutes")
        let initialRange = try XCTUnwrap(task.value as? String)
        let startLabel = try XCTUnwrap(initialRange.components(separatedBy: " – ").first)

        let first = try XCTUnwrap(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        let firstLabel = app.descendants(matching: .any)["day-hour-\(Int(first.timeIntervalSince1970))"].firstMatch
        let nextLabel = app.descendants(matching: .any)["day-hour-\(Int(first.addingTimeInterval(3600).timeIntervalSince1970))"].firstMatch
        let pointsPerHour = nextLabel.frame.minY - firstLabel.frame.minY
        XCTAssertGreaterThan(pointsPerHour, 0)
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.12, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: pointsPerHour * 12 / 60)))
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "17 minutes"), object: handle)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 8), .completed)
        let resizedRange = try XCTUnwrap(task.value as? String)
        XCTAssertTrue(resizedRange.hasPrefix(startLabel + " – "))
        XCTAssertNotEqual(resizedRange, initialRange)

        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 8))
        XCTAssertEqual(handle.value as? String, "17 minutes")
        XCTAssertEqual(task.value as? String, resizedRange)
    }

    func testHoldingScheduledTaskOverWeekDayOpensItsTimeline() throws {
        let app = launch()
        let title = "Send the paper proof"
        app.buttons["Quick add"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes tomorrow")
        app.buttons["Add to inbox"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let today = Calendar.current.startOfDay(for: .now)
        let sourceDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        let targetDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: today))
        func row(on day: Date) -> XCUIElement {
            let prefix = "week-task-\(Int(day.timeIntervalSince1970))-"
            return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", prefix, title)).firstMatch
        }
        let source = row(on: sourceDay)
        let chip = app.buttons["plan-day-\(Int(targetDay.timeIntervalSince1970))"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        if !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable && chip.isHittable)
        XCTAssertFalse(app.buttons["week-back-to-overview"].exists)
        source.press(forDuration: 0.8, thenDragTo: chip, withVelocity: .default, thenHoldForDuration: 1.2)
        XCTAssertTrue(app.buttons["week-back-to-overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(row(on: targetDay).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["day-task-drawer"].isHittable)
    }

    func testWeekOverviewDragRevealsDestinationAndPulseCanPickAcrossDays() throws {
        let app = launch()
        let title = "Pack the field notebook"
        app.buttons["Quick add"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "quick-capture-input").firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes tomorrow")
        app.buttons["Add to inbox"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let calendar = Calendar.current
        let baseline = calendar.startOfDay(for: .now)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: baseline))
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: baseline))
        func agendaTask(on day: Date) -> XCUIElement {
            let prefix = "week-task-\(Int(day.timeIntervalSince1970))-"
            return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, title)).firstMatch
        }
        XCTAssertTrue(agendaTask(on: tomorrow).waitForExistence(timeout: 10))
        let destination = app.buttons["plan-day-\(Int(later.timeIntervalSince1970))"]
        let source = agendaTask(on: tomorrow)
        XCTAssertTrue(destination.exists && source.exists)
        source.press(forDuration: 0.8, thenDragTo: destination)
        let moved = agendaTask(on: later)
        XCTAssertTrue(moved.waitForExistence(timeout: 10))
        XCTAssertFalse(agendaTask(on: tomorrow).exists)
        XCTAssertTrue(app.buttons["Undo time change"].firstMatch.exists)
        moved.tap()
        app.buttons["week-timing-pick"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Scheduled for")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(agendaTask(on: tomorrow).waitForExistence(timeout: 5))
        app.buttons["Undo time change"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Previous timing restored."].waitForExistence(timeout: 5))
        XCTAssertTrue(agendaTask(on: later).waitForExistence(timeout: 5))
    }

    func testWeekShowsSevenAgendasAndCreatesABlockForTheLastDay() throws {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<7 {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            let heading = app.descendants(matching: .any)["week-agenda-\(Int(date.timeIntervalSince1970))"].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 5), "Agenda for " + date.formatted())
        }
        let lastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: today))
        let stamp = Int(lastDay.timeIntervalSince1970)
        let dayButton = app.buttons["plan-day-\(stamp)"]
        dayButton.tap()
        XCTAssertTrue(app.buttons["week-back-to-overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["day-task-drawer"].isHittable)
        app.buttons["week-day-tools"].tap()
        app.buttons["timeline-draw-toggle"].tap()
        app.buttons["Protected"].tap()
        app.buttons["review-timeline-block"].tap()
        app.buttons["save-timeline-block"].tap()
        app.buttons["week-back-to-overview"].tap()
        let lastSection = app.descendants(matching: .any)["week-section-\(stamp)"].firstMatch
        let saved = lastSection.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Protected time")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
    }

    func testAddToPlanCreatesABlockOnTomorrow() throws {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
        app.buttons["Add to plan"].tap()
        app.buttons["add-plan-new-block"].tap()
        app.buttons["Protected time"].tap()
        let name = app.textFields["Name (optional)"]
        name.tap()
        name.typeText("Dinner with Ada")
        app.buttons["Save"].tap()

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Dinner with Ada")).firstMatch
            .waitForExistence(timeout: 8))
    }

    private func createShortTaskAndOpenTomorrow(_ title: String, in app: XCUIApplication) {
        app.buttons["Quick add"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes")
        app.buttons["Add to inbox"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
    }

    func testDragHeldTaskFromWeekDrawerIntoFocusThenOntoADayAndBack() throws {
        let app = launch()
        app.addFocusFixture()
        let title = "Sort the studio notes"
        app.buttons["Start"].tap()
        app.buttons["Capture distraction"].tap()
        let field = app.descendants(matching: .any)["quick-capture-input"].firstMatch
        field.tap()
        field.typeText(title + " for 5 minutes")
        app.buttons["save-quick-capture"].tap()
        app.buttons["Finish session"].tap()
        app.buttons["Mark task complete"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Tomorrow"].tap()
        app.buttons["Add to plan"].tap()
        app.buttons["add-plan-new-block"].tap()
        let name = app.textFields["Name (optional)"]
        name.tap()
        name.typeText("Notebook focus")
        app.buttons["Save"].tap()

        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()
        let drawer = app.buttons["day-task-drawer"]
        let task = app.buttons["Schedule " + title].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        if !task.exists { drawer.tap() }
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agenda-focus-' AND label CONTAINS %@", "Notebook focus")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5) && target.exists)
        let center = CGVector(dx: 0.5, dy: 0.5)
        func drag(_ source: XCUIElement, to destination: XCUIElement) {
            source.coordinate(withNormalizedOffset: center).press(forDuration: 0.8, thenDragTo: destination.coordinate(withNormalizedOffset: center))
        }
        if !target.isHittable { app.swipeUp() }
        drag(task, to: target)
        let undo = app.buttons["Undo time change"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8))
        XCTAssertFalse(task.exists)
        target.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        undo.tap()
        if (drawer.value as? String)?.hasSuffix("collapsed") == true { drawer.tap() }
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        let later = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: .now)))
        let destination = app.buttons["plan-day-\(Int(later.timeIntervalSince1970))"]
        if !destination.isHittable { app.swipeDown() }
        drag(task, to: destination)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                   "week-task-\(Int(later.timeIntervalSince1970))-", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        if !row.isHittable { app.swipeUp() }
        drag(row, to: drawer)
        XCTAssertTrue(task.waitForExistence(timeout: 8))
        XCTAssertTrue(row.waitForNonExistence(timeout: 8))
    }

    func testTapWeekDrawerTaskThenDayToScheduleAnExactMinute() throws {
        let app = launch()
        let title = "Outline next chapter"
        app.buttons["tab-Plan"].tap()
        app.buttons["New task"].tap()
        let name = app.textFields["Task name"]
        name.tap()
        name.typeText(title)
        app.buttons["Save"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let drawer = app.buttons["day-task-drawer"]
        drawer.tap()
        let task = app.buttons["Schedule " + title].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        let calendar = Calendar.current
        let later = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: .now)))
        let stamp = Int(later.timeIntervalSince1970)
        let day = app.buttons["plan-day-\(stamp)"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        let sheet = app.navigationBars["Set time"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let picker = app.datePickers["week-exact-start"]
        if app.pickerWheels.count == 0 { picker.tap() }
        let minute = app.pickerWheels.element(boundBy: 1)
        XCTAssertTrue(minute.waitForExistence(timeout: 5))
        minute.adjust(toPickerWheelValue: "17")
        sheet.staticTexts["Set time"].tap()
        app.buttons["week-exact-save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                   "week-task-\(stamp)-", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let expected = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 17, second: 0, of: later))
        XCTAssertTrue((row.value as? String)?.hasPrefix(expected.formatted(date: .omitted, time: .shortened) + ",") == true)
    }

    func testChooseTaskWhileDrawingAFocusBlock() throws {
        let app = launch()
        let name = "Sort the postcards"
        createShortTaskAndOpenTomorrow(name, in: app)
        app.buttons["week-day-tools"].tap()
        app.buttons["timeline-draw-toggle"].tap()
        let inline = app.buttons["timeline-choose-block-task"]
        inline.tap()
        app.buttons[name].firstMatch.tap()
        XCTAssertTrue(inline.label.contains(name))
        app.buttons["review-timeline-block"].tap()
        let choice = app.buttons["focus-block-task-choice"]
        choice.tap()
        app.buttons["No task"].tap()
        choice.tap()
        app.buttons[name].firstMatch.tap()
        app.buttons["save-timeline-block"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()

        let day = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "week-task-\(Int(day.timeIntervalSince1970))-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let time = try XCTUnwrap(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        XCTAssertTrue((row.value as? String)?.hasPrefix(time.formatted(date: .omitted, time: .shortened)) == true)
    }

    func testAddToPlanSavesChosenTaskOnlyOnConfirmation() {
        let app = launch()
        let name = "Pack the paintbrush"
        createShortTaskAndOpenTomorrow(name, in: app)
        func openBlockEditor() {
            app.buttons["Add to plan"].tap()
            app.buttons["add-plan-new-block"].tap()
        }
        openBlockEditor()
        let choice = app.buttons["focus-block-task-choice"]
        choice.tap()
        app.buttons[name].firstMatch.tap()
        app.buttons["Protected time"].tap()
        XCTAssertFalse(choice.exists)
        app.buttons["Focus time"].tap()
        choice.tap()
        app.buttons[name].firstMatch.tap()
        app.buttons["Cancel"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'week-task-' AND label == %@", name)).firstMatch.exists)

        openBlockEditor()
        choice.tap()
        app.buttons[name].firstMatch.tap()
        app.buttons["Save"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'week-task-' AND label == %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Week"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let focus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agenda-focus-' AND label CONTAINS %@", "Focus time")).firstMatch
        focus.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.waitForExistence(timeout: 5))
    }

    func testDistractionCapturePreviewsTimeAndReturnsToRunningFocus() {
        let app = launch()
        app.addFocusFixture()
        app.buttons["start-small"].tap()
        app.buttons["Capture distraction"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "quick-capture-input").firstMatch
        field.tap()
        field.typeText("Water plants in 20 minutes")
        let timing = app.staticTexts["capture-timing"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        XCTAssertTrue(timing.label.contains("Earliest"))
        let save = app.buttons["save-quick-capture"]
        XCTAssertEqual(save.label, "Add to plan")
        save.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Return to focus"].exists)
    }

    func testUnfinishedSprintCaptureSurvivesRelaunchSeparatelyFromOrdinaryDraft() {
        let app = launch()
        let input = app.descendants(matching: .any).matching(identifier: "quick-capture-input").firstMatch
        let ordinary = "Remember the greenhouse key"
        let distraction = "Bring the red notebook"

        func reopen() {
            XCUIDevice.shared.press(.home)
            app.terminate()
            app.launch()
        }

        app.buttons["Quick add"].tap()
        input.tap()
        input.typeText("Read garden notes for 10 minutes")
        app.buttons["Add to inbox"].tap()
        app.buttons["Quick add"].tap()
        input.tap()
        input.typeText(ordinary)
        reopen()

        app.buttons["start-small"].tap()
        app.buttons["Capture distraction"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertNotEqual(input.value as? String, ordinary)
        input.tap()
        input.typeText(distraction)
        reopen()
        app.buttons["Finish step"].tap()
        let review = app.buttons["Review 1 capture"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        reopen()
        review.tap()
        app.buttons["finish-sprint-draft"].tap()
        XCTAssertEqual(input.value as? String, distraction)
        app.buttons["Add to inbox"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: distraction).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        app.buttons["Quick add"].tap()
        XCTAssertEqual(input.value as? String, ordinary)
        app.buttons["Add to inbox"].tap()
        review.tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: distraction).firstMatch.exists)
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: ordinary).firstMatch.exists)
        XCTAssertFalse(app.buttons["finish-sprint-draft"].exists)
    }

    func testFocusPauseRestoreAndFinish() throws {
        let app = launch()
        app.addFocusFixture()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        capture(app, "Today")
        start.tap()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].exists)
        capture(app, "Focus")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 10))
        app.buttons["Return to Today"].tap()
        XCTAssertTrue(app.buttons["Return to focus"].waitForExistence(timeout: 5))
        app.buttons["Return to focus"].tap()
        app.buttons["Resume"].tap()
        XCTAssertFalse(app.buttons["tab-Plan"].isHittable)
        app.buttons["Finish session"].tap()
        app.buttons["Mark task complete"].tap()
        XCTAssertTrue(app.staticTexts["Room to breathe"].waitForExistence(timeout: 5))
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["All items"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Completed").firstMatch.exists)
    }
    func testFinishFocusAfterCheckingInDuringSession() {
        let app = launch()
        app.addFocusFixture()
        let start = app.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        app.buttons["Return to Today"].tap()
        app.buttons["check-in"].tap()
        app.buttons["Optional details"].tap()
        app.buttons["Back to ratings"].tap()
        app.buttons["Save check-in"].tap()
        app.buttons["Return to focus"].tap()
        app.buttons["Finish session"].tap()
        let complete = app.buttons["Mark task complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertTrue(app.staticTexts["Room to breathe"].waitForExistence(timeout: 5))
    }

    func testQuickCaptureAndFinishOneSmallStep() {
        let app = launch()
        app.buttons["Quick add"].tap()
        let entry = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        entry.tap()
        entry.typeText("Study botany for 12 minutes by tomorrow")
        app.buttons["Add to inbox"].tap()
        XCTAssertTrue(app.staticTexts["Study botany"].waitForExistence(timeout: 5))
        app.buttons["Not now"].tap()
        app.buttons["Try a smaller step"].tap()
        app.buttons["Start first step"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Finish step"].tap()
        app.buttons["End break"].tap()
        XCTAssertTrue(app.staticTexts["Study botany"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start"].exists)
    }
    func testShortSessionCanBeMovedToTomorrow() {
        let app = launch()
        app.addFocusFixture()
        app.buttons["Day overview"].tap()
        app.buttons["Spare moment"].tap()
        app.buttons["5 min"].tap()
        app.buttons["Start Write a letter"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Finish session"].tap()
        app.buttons["Save progress for later"].tap()
        app.buttons["tab-Plan"].tap()
        app.buttons["plan-view"].tap()
        app.buttons["Close out today"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "day-close-task-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["day-close-move"].tap()
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        app.buttons["day-close-move"].tap()
        app.alerts.buttons["Move to tomorrow"].tap()
        XCTAssertTrue(app.staticTexts["1 task moved to tomorrow."].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }

    func testCheckInAndInspectObservations() throws {
        let app = launch()
        app.buttons["check-in"].tap()
        app.sliders["Physical energy"].adjust(toNormalizedSliderPosition: 0.2)
        app.sliders["Mental clarity"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["Interest"].adjust(toNormalizedSliderPosition: 0.8)
        capture(app, "Check-in")
        app.buttons["Save check-in"].tap()
        XCTAssertEqual(app.buttons["check-in"].value as? String, "Energy 2 out of 10")
        app.buttons["tab-Health"].tap()
        app.buttons["health-jump-check-ins"].tap()
        XCTAssertTrue(app.staticTexts["2 / 10"].exists)
        app.buttons["measure"].tap()
        app.buttons["Clarity"].tap()
        XCTAssertTrue(app.staticTexts["7 / 10"].exists)
        app.buttons["measure"].tap()
        app.buttons["Interest"].tap()
        XCTAssertTrue(app.staticTexts["8 / 10"].exists)
        app.buttons["measure"].tap()
        app.buttons["Energy"].tap()
        capture(app, "Health check-ins")
        app.buttons["Last 7 days"].tap()
        XCTAssertTrue(app.staticTexts["2 / 10"].exists)
        app.terminate()
        app.launch()
        app.buttons["tab-Health"].tap()
        app.buttons["health-jump-check-ins"].tap()
        XCTAssertTrue(app.staticTexts["2 / 10"].exists)
    }
    func testParsePlanAndRest() throws {
        let app = launch()
        app.buttons["tab-Plan"].tap()
        app.buttons["Planning options"].tap()
        app.buttons["Add to plan"].tap()
        let input = app.textFields.firstMatch
        if input.exists {
            input.tap()
            input.typeText("Study chemistry for 12 minutes")
        } else {
            let field = app.textViews.firstMatch
            field.tap()
            field.typeText("Study chemistry for 12 minutes")
        }
        app.buttons["Preview plan"].tap()
        app.buttons["Add these items"].tap()
        app.buttons["tab-Today"].tap()
        XCTAssertTrue(app.staticTexts["Study chemistry"].firstMatch.exists)
        app.buttons["Not now"].tap()
        app.buttons["Rest for today"].tap()
        XCTAssertTrue(app.staticTexts["A day to rest"].exists)
        app.buttons["Resume planning"].tap()
        XCTAssertTrue(app.buttons["Start"].exists)
    }
}
