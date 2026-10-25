import Core
import Foundation

public final class SecurityHealthTask {
  private let fileVault: FileVaultStatusSource
  private let lock = NSLock()
  private var status = DeviceSecurityHealth()
  private var lastRead: Int?
  public init(fileVault: FileVaultStatusSource, storage: StorageSecurityHealth) {
    self.fileVault = fileVault
    status.backupExclusionFailure = storage.backupExclusionFailure
  }
  public var health: DeviceSecurityHealth {
    lock.lock(); defer { lock.unlock() }; return status
  }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: "security-health") { now in
      self.lock.lock()
      if let lastRead = self.lastRead, now < lastRead {
        // Start a fresh hour after a backward clock jump without another read.
        self.lastRead = now
        self.lock.unlock()
        return
      }
      if let lastRead = self.lastRead, Double(now) - Double(lastRead) < 3600 {
        self.lock.unlock()
        return
      }
      self.lastRead = now
      self.lock.unlock()
      let value = self.fileVault.fileVaultStatus()
      self.lock.lock(); defer { self.lock.unlock() }
      self.status.fileVault = value
    }
  }
}
