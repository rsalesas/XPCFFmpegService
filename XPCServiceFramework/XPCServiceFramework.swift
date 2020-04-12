import Foundation


// Creates a listener delegate for the specified interface/object and mode
public class XPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    
    public enum ListenerMode {
        case service
        case anonymous
    }
    
    fileprivate let listener: NSXPCListener
    
    public let exportedInterface: Protocol
    public let exportedObject: Any
    
    public init(mode: ListenerMode, interface: Protocol, object: Any) {
        self.exportedInterface = interface
        self.exportedObject = object
        self.listener = (mode == .service) ? NSXPCListener.service() : NSXPCListener.anonymous()
        
        super.init()
        
        self.listener.delegate = self
    }
    
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: exportedInterface)
        newConnection.exportedObject = exportedObject
        newConnection.resume()
        return true
    }
    
    public func resume() {
        listener.resume()
    }
    
    public func suspend() {
        listener.suspend()
    }
    
    public func invalidate() {
        listener.invalidate()
    }
}


// Creates a service listener for the specified interface/object
public class XPCServiceListenerDelegate: XPCListenerDelegate {
        
    public init(interface: Protocol, object: Any) {
        super.init(mode: .service, interface: interface, object: object)
    }
}


// Creates a anonymous listener for the specified interface/object
public class XPCAnonymousListenerDelegate: XPCListenerDelegate {
        
    public var endpoint: NSXPCListenerEndpoint {
        get {
            return listener.endpoint
        }
    }
    
    public init(interface: Protocol, object: Any) {
        super.init(mode: .anonymous, interface: interface, object: object)
    }

}


// Connection/proxy classes
public protocol XPCServiceProxyProtocol : class {
    associatedtype Service
    
    var service: Service { get }
    
    func reconnect()
    
    func resume()
    
    func suspend()

    func invalidate()

}


public protocol XPCServiceProxyDelegateProtocol : class {

    func interruption()
    
    func invalidation()
    
    func connectionError(error: Error)
    
}


public class XPCServiceProxy<Service>: XPCServiceProxyProtocol {
        
    private var serviceName: String
    private var `protocol`: Protocol
    
    private var connection: NSXPCConnection
    private weak var delegate: XPCServiceProxyDelegateProtocol?
    
    private lazy var _service: Service = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.delegate?.connectionError(error: error)
        } as! Service
    
    public var service: Service {
        get {
            return _service
        }
    }

    public init(serviceName: String, protocol: Protocol, delegate: XPCServiceProxyDelegateProtocol? = nil) {
        self.serviceName = serviceName
        self.protocol = `protocol`
        self.delegate = delegate
        
        connection = XPCServiceProxy.connect(serviceName: serviceName, protocol: `protocol`, delegate: delegate)
        
        if self.delegate == nil, self is XPCServiceProxyDelegateProtocol {
            self.delegate = self as? XPCServiceProxyDelegateProtocol
        }
    }
    
    public func reconnect() {
        connection = XPCServiceProxy.connect(serviceName: self.serviceName, protocol: self.protocol, delegate: delegate)
    }
    
    private static func connect(serviceName: String, protocol: Protocol, delegate: XPCServiceProxyDelegateProtocol?) -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: `protocol`)
        
        connection.interruptionHandler = { [weak delegate] in
            delegate?.interruption()
        }
            
        connection.invalidationHandler =  { [weak delegate] in
            delegate?.interruption()
        }

        return connection
    }

    public func resume() {
        connection.resume()
    }
    
    public func suspend() {
        connection.suspend()
    }
    
    public func invalidate() {
        connection.invalidate()
    }

}


// Factory XPC service classes

/*
 public typealias Result = Swift.Result<NSXPCListenerEndpoint, FactoryError>
 public typealias CompletionHandler = (_ result: Result) -> Void
 */

@objc
public protocol XPCServiceFactoryProtocol : class {
    
    typealias CompletionHandler = (_ endpoint: NSXPCListenerEndpoint?, _ error: Error?) -> Void

    func request(serviceName: String, reply handler: @escaping (XPCServiceFactoryProtocol.CompletionHandler))

    func suspend(serviceName: String)
}


public class XPCServiceFactory: XPCServiceFactoryProtocol {

    public enum FactoryError: Int, Error, Codable {
        case notFound
    }
    
    public typealias ServiceDictionary = [String : XPCAnonymousListenerDelegate]
    
    private var services : ServiceDictionary
    
    
    init(services: ServiceDictionary) {
        self.services = services
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

public class XPCFactoryServiceListenerDelegate: XPCServiceListenerDelegate {
    
    public init(services: XPCServiceFactory.ServiceDictionary) {
        super.init(interface: XPCServiceFactoryProtocol.self, object: XPCServiceFactory(services: services))
    }
}


