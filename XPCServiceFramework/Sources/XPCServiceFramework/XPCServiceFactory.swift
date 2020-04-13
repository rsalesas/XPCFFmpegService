import Foundation
import SiliconInk_Helper


// Factory XPC service classes
@objc
public protocol XPCServiceFactoryProtocol : class {
    
    typealias CompletionHandler = (_ endpoint: NSXPCListenerEndpoint?, _ error: Error?) -> Void
    
    func request(serviceName: String, reply handler: @escaping (XPCServiceFactoryProtocol.CompletionHandler))

    func suspend(serviceName: String)
}


public class XPCServiceFactory: XPCServiceListenerDelegate, XPCServiceFactoryProtocol {

    public enum FactoryError: Int, Error, Codable {
        case notFound
        case unexpectedResult
    }
    
    public typealias ServiceDictionary = [String : XPCAnonymousListenerDelegate]
    
    private var services : ServiceDictionary
    
    
    public init(services: ServiceDictionary) {
        self.services = services
        super.init(interface: XPCServiceFactoryProtocol.self)
    }
    
    public func request(serviceName: String, reply handler: @escaping (XPCServiceFactoryProtocol.CompletionHandler)) {
        if let service = services[serviceName] {
            service.resume()
            handler(service.endpoint, nil)
            
        } else {
            handler(nil, FactoryError.notFound)
            return
        }
    }
    
    public func suspend(serviceName: String) {
        if let service = services[serviceName] {
            service.suspend()
        }
    }
}

public class XPCServiceFactoryProxy: XPCServiceProxy<XPCServiceFactoryProtocol> {
    
    public typealias Result = Swift.Result<NSXPCListenerEndpoint, XPCServiceFactory.FactoryError>

    public typealias CompletionHandler = (_ result: XPCServiceFactoryProxy.Result) -> Void
    
    
    public init(serviceName: String) {
        super.init(serviceName: serviceName, protocol: XPCServiceFactoryProtocol.self)
    }
    
    public func request(serviceName: String, reply handler: @escaping (XPCServiceFactoryProxy.CompletionHandler)) {
        proxy.request(serviceName: serviceName) { endpoint, error in
            handler(Result.init(success: endpoint, failure: error))
        }
    }
    
    public func suspend(serviceName: String) {
        proxy.suspend(serviceName: serviceName)
    }
}
