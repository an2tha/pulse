# pulse

a quieter way to plan your day around the energy you have.

pulse is a native iOS app for catching tasks, making room for them, and getting started when a whole task feels like too much. it brings a daily plan, short focus sessions, check-ins, and an estimated energy rhythm into one place.

## what you can do

- capture a thought quickly and sort it out later.
- schedule tasks around appointments, recurring routines, and breathing room.
- start with a two-minute sprint, save a distraction, and leave a note for next time.
- check in on energy, clarity, and interest.
- use the energy curve to spot estimated peaks and dips.
- move your sleep window and preview how a different schedule could affect the next day.
- connect Apple Health, Calendar, Reminders, or OneRep when you want to.
- keep a photo journal, export your data, and optionally sync through an encrypted folder.

there is a demo journal in the welcome screen if you want to look around first.

## about the energy curve

the curve starts with a rough mathematical rhythm based on sleep timing. it combines a daily body-clock cycle with sleep pressure that builds while awake and falls during sleep, plus an allowance for grogginess after waking.

as you use pulse, recorded sleep, recent sleep debt, check-ins near the same hour, weekday patterns, and comparable recovery readings help refine the estimates. recent observations have more influence, and repeated check-ins on a single day count together. your manual corrections take priority.

dragging a sleep handle previews the proposed schedule before saving it. moving one end preserves the duration. adjusting the other end makes both times independent. shortening the window opens a drawer showing the change.

the sleep preview assumes a repeating schedule. your actual body clock can take days to adjust. the 0–10 scale and peak times are planning estimates, and their accuracy for predicting how you feel has not been clinically validated.

the starting model is inspired by the two-process model of sleep regulation. [research background](https://pmc.ncbi.nlm.nih.gov/articles/PMC9540767/)

## running it

you will need a Mac, a recent Xcode with Swift 6 support, and an iOS simulator or an iPhone running iOS 17 or later.

1. open `Pulse.xcodeproj` in Xcode.
2. select the `Pulse` scheme and a simulator.
3. build and run.

to run on your own phone, select your signing team for the app and its extensions. you may also need to change the bundle identifiers and app group to match your account.

Apple Health and Screen Time features need compatible devices and permissions. the rest of the app can be explored without connecting them.

## checking changes

the planning engine is a standalone Swift package. run its tests from the repository root.

```sh
cd PulseEngine
swift test
```

the app also has unit tests and UI tests in Xcode. use the `Pulse` scheme and choose Product > Test, or run against an available simulator.

```sh
xcodebuild test \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

replace the simulator name with one installed on your Mac.

## finding your way around

| folder | what lives there |
| --- | --- |
| `PulseApp` | SwiftUI screens, workspace state, local storage, and connections |
| `PulseEngine` | scheduling, energy estimates, recurring tasks, and engine tests |
| `PulseAppTests` | app and storage tests |
| `PulseUITests` | interaction tests |
| `PulseShared` | data and actions shared with extensions |
| `PulseWidgets` | widgets and live activity controls |
| `PulseShare` | the share extension |
| `PulseScreenTime` | the Screen Time report extension |
| `Config` | app configuration and entitlements |
| `Previews` | screenshots and walkthrough recordings |
| `docs` | implementation notes and sync details |

## your data

your journal starts on your device. external connections and private sync are optional. connection credentials are kept in the device Keychain.

private sync uses a folder you choose and a recovery key you keep. the sync notes explain what is included, how conflicts work, and how recovery works. [private sync details](docs/private-sync.md)

JSON and CSV exports are unencrypted files. keep them somewhere appropriate for the information they contain.
