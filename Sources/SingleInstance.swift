import Foundation
import Darwin

enum SingleInstance {
    private static var descriptor: Int32 = -1
    static func acquire() throws -> Bool {
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("local.bandwagon.monitor",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fd = open(directory.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR,0o600)
        guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        if flock(fd,LOCK_EX | LOCK_NB) != 0 {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return false }
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
        _ = fcntl(fd,F_SETFD,FD_CLOEXEC)
        descriptor = fd // OS releases the lock when this process exits.
        return true
    }
    static func test() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock")
        defer { try? FileManager.default.removeItem(at:file) }
        let first = open(file.path,O_CREAT | O_RDWR,0o600)
        let second = open(file.path,O_RDWR)
        guard first >= 0, second >= 0 else { throw NSError(domain:"Lock test",code:1) }
        defer { close(first); close(second) }
        guard flock(first,LOCK_EX | LOCK_NB) == 0,
              flock(second,LOCK_EX | LOCK_NB) != 0,
              flock(first,LOCK_UN) == 0,
              flock(second,LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain:"Lock test",code:2) }
        print("PASS: 排他进程锁阻止重复实例，释放后可再次启动")
    }
}
