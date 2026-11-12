import AppKit
import Darwin
import Foundation
// Trusted native bridge only; synthetic loopback negotiation stops before TLS/auth.
guard CommandLine.arguments.count == 2 else { fatalError("Expected runtime directory") }
let runtime = URL(fileURLWithPath: CommandLine.arguments[1])
let handle = dlopen(runtime.appendingPathComponent("Frameworks/libNethrivaRDP.dylib").path, RTLD_NOW | RTLD_LOCAL)!
func symbol<T>(_ name: String, _ type: T.Type) -> T { unsafeBitCast(dlsym(handle,name)!, to:type) }
let configure = symbol("NethrivaRDPConfigureOpenSSL", (@convention(c)(UnsafePointer<CChar>?) -> Int32).self)
let create = symbol("NethrivaRDPCreateView", (@convention(c)(Double,Double) -> UnsafeMutableRawPointer?).self)
let setConfig = symbol("NethrivaRDPSetConfigPath", (@convention(c)(UnsafeMutableRawPointer?,UnsafePointer<CChar>?) -> Int32).self)
let start = symbol("NethrivaRDPStart", (@convention(c)(UnsafeMutableRawPointer?,Int32,UnsafePointer<UnsafePointer<CChar>?>?) -> Int32).self)
let destroy = symbol("NethrivaRDPDestroy", (@convention(c)(UnsafeMutableRawPointer?) -> Void).self)
NSApplication.shared.setActivationPolicy(.prohibited)
precondition(runtime.appendingPathComponent("Frameworks/ossl-modules").path.withCString { configure($0) } == 1)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("NethrivaCookieTest-"+UUID().uuidString)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer { try? FileManager.default.removeItem(at:root) }
let listener = socket(AF_INET,SOCK_STREAM,0); precondition(listener >= 0)
defer { close(listener) }
var timeout = timeval(tv_sec:5,tv_usec:0)
precondition(setsockopt(listener,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size)) == 0)
var address = sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
precondition(withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(listener,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
precondition(listen(listener,1)==0)
var length=socklen_t(MemoryLayout<sockaddr_in>.size)
precondition(withUnsafeMutablePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(listener,$0,&length) } }==0)
let port=UInt16(bigEndian:address.sin_port)
let session=create(640,480)!
precondition(root.path.withCString { setConfig(session,$0) } == 1)
let arguments=["/v:127.0.0.1:\(port)","/u:synthetic-wire-user","/sec:nla","/cert:deny","/auth-only","/timeout:3000"]
let storage=arguments.map { strdup($0)! };defer { storage.forEach { free($0) } }
let pointers=storage.map { Optional(UnsafePointer($0)) }
precondition(pointers.withUnsafeBufferPointer { start(session,Int32(pointers.count),$0.baseAddress) }==0)
let connection=accept(listener,nil,nil);precondition(connection>=0)
var bytes=[UInt8](repeating:0,count:4096)
let count=recv(connection,&bytes,bytes.count,0);close(connection);precondition(count>0)
let packet=Data(bytes.prefix(count))
precondition(packet.range(of:Data("synthetic-wire-user".utf8))==nil)
precondition(packet.range(of:Data("Cookie: mstshash=\r\n".utf8)) != nil)
RunLoop.current.run(until:Date().addingTimeInterval(0.2))
destroy(session)
print("PASS: actual final bridge initial RDP packet (\(count) bytes) omits the synthetic username (empty routing cookie); loopback closed before TLS; no password supplied.")
