import Foundation
import AppKit
import SiliconInk_Helper
import XPCFFmpegServiceFramework
    

class XPCFFmpegInvoke: XPCServiceListenerDelegate, XPCFFmpegInvokeProtocol {   
    
    public init() {
        super.init(interface: XPCFFmpegInvokeProtocol.self)
    }

    func invoke(endpoint: NSXPCListenerEndpoint, request: String, globalOptions: [String], inputs: [String], filters: [String], outputs: [String], url: Data, reply handler: @escaping (CompletionHandler)) {
        
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: XPCFFmpegStatusProtocol.self)
        connection.resume()
        
        // TODO: This should be handled in a way that lets the caller retry, etc.
        let service = connection.remoteObjectProxyWithErrorHandler { error in
                print("Received error:", error)
            } as! XPCFFmpegStatusProtocol

        ProcessInfo.processInfo.disableAutomaticTermination("XPCFFmpegInvoke starting long-running command.")
        defer { ProcessInfo.processInfo.enableAutomaticTermination("XPCFFmpegInvoke finished long-running command.") }
        
        let ffmpegTaskProcess = FFmpegTaskProcess(statusService: service, completionHandler: { result in
            switch result {
            case .success(let object):
                handler(object, nil)
                
            case .failure(let error):
                handler(nil, error)
            }
        })
        
        let url = try! URL(resolvingBookmarkData: url)
        let newInput = inputs + [url.path]
        
        ffmpegTaskProcess.invoke(arguments: [request] + globalOptions + newInput + filters + outputs)
    }
    
}



