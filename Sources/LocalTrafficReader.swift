import Foundation
import Darwin
import SystemConfiguration

// Read 64-bit kernel counters; getifaddrs' if_data counters can wrap at 4 GiB.
enum LocalTrafficReader {
    static func read() throws -> (counters: [String:LocalCounter], boot: String) {
        var bootTime = timeval(), bootSize = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime",&bootTime,&bootSize,nil,0) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { throw NSError(domain:"LocalInterfaces",code:1) }
        var allowed = Set<String>()
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?, let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
            if name.hasPrefix("en") && (type == kSCNetworkInterfaceTypeEthernet || type == kSCNetworkInterfaceTypeIEEE80211) { allowed.insert(name) }
        }
        var mib: [Int32] = [CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0]
        var data = Data()
        var succeeded = false
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib,u_int(mib.count),nil,&size,nil,0) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            data = Data(count:size)
            let result = data.withUnsafeMutableBytes { raw in sysctl(&mib,u_int(mib.count),raw.baseAddress,&size,nil,0) }
            if result == 0 { data.count = size; succeeded = true; break }
            if errno != ENOMEM { break }
        }
        guard succeeded else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        var counters: [String:LocalCounter] = [:]
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 4 <= raw.count {
                let length = Int(raw.loadUnaligned(fromByteOffset:offset,as:UInt16.self))
                guard length >= 4, offset + length <= raw.count else { throw NSError(domain:"LocalCounterFormat",code:1) }
                if raw[offset+3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let header = raw.loadUnaligned(fromByteOffset:offset,as:if_msghdr2.self)
                    var buffer = [CChar](repeating:0,count:Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.ifm_index),&buffer) != nil {
                        let name = String(cString:buffer)
                        if allowed.contains(name), header.ifm_flags & IFF_LOOPBACK == 0 {
                            counters[name] = LocalCounter(index:UInt32(header.ifm_index),uploaded:header.ifm_data.ifi_obytes,downloaded:header.ifm_data.ifi_ibytes)
                        }
                    }
                }
                offset += length
            }
        }
        return (counters,"\(bootTime.tv_sec):\(bootTime.tv_usec)")
    }
}
