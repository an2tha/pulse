import Foundation
import PulseEngine

extension Workspace {
    var energyActivities: [EnergyActivity] { EnergyActivity.presets + (journal.customEnergyActivities ?? []) }

    @discardableResult func saveEnergyActivity(_ activity: EnergyActivity) -> Bool {
        guard ready, !restoring, activity.isValid, (activity.kind == .boost || !energyActivityIsScheduled(activity.id)), !EnergyActivity.presets.contains(where: { $0.id == activity.id }),
              !energyActivities.contains(where: { $0.id != activity.id && $0.title.localizedCaseInsensitiveCompare(activity.title) == .orderedSame })
        else { return false }
        change { journal in
            var custom = journal.customEnergyActivities ?? []
            if let i = custom.firstIndex(where: { $0.id == activity.id }) { custom[i] = activity }
            else { custom.append(activity) }
            journal.customEnergyActivities = custom
        }
        return true
    }

    func energyActivityIsScheduled(_ id: UUID) -> Bool {
        journal.timeBlocks?.contains(where: { $0.boostActivityID == id }) == true
    }

    @discardableResult func deleteEnergyActivity(_ id: UUID) -> Bool {
        guard ready, !restoring, !energyActivityIsScheduled(id),
              journal.customEnergyActivities?.contains(where: { $0.id == id }) == true else { return false }
        change { $0.customEnergyActivities?.removeAll { $0.id == id } }
        return true
    }

    @discardableResult func recordEnergyActivity(_ log: EnergyActivityLog, at date: Date = .now) -> Bool {
        guard ready, !restoring, log.isValid, log.started <= date, (log.finished ?? log.started) <= date,
              energyActivities.contains(where: { $0.id == log.activity.id }),
              !(journal.energyActivityLogs ?? []).contains(where: { $0.id == log.id }) else { return false }
        change { journal in
            var history = journal.energyActivityLogs ?? []
            history.append(log)
            journal.energyActivityLogs = history
        }
        return true
    }

    @discardableResult func finishEnergyActivity(_ id: UUID, after: Int, at date: Date = .now) -> Bool {
        guard ready, !restoring, (0...10).contains(after),
              let index = journal.energyActivityLogs?.firstIndex(where: { $0.id == id && $0.after == nil && $0.started <= date }) else { return false }
        change {
            $0.energyActivityLogs?[index].after = after
            $0.energyActivityLogs?[index].finished = date
        }
        return true
    }
}
