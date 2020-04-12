import Foundation


// Creates a listener delegate for the specified interface/object and mode
public class XPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    
    fileprivate enum ListenerMode {
        case service
        case anonymous
    }
    
    
    fileprivate let listener: NSXPCListener
    
    private let interface: Protocol
    
    fileprivate init(mode: ListenerMode, interface: Protocol) {
        self.interface = interface
        self.listener = (mode == .service) ? NSXPCListener.service() : NSXPCListener.anonymous()
        
        super.init()
        
        self.listener.delegate = self
    }
    
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: interface)
        newConnection.exportedObject = self
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
        
    public init(interface: Protocol) {
        super.init(mode: .service, interface: interface)
    }
}


// Creates a anonymous listener for the specified interface/object
public class XPCAnonymousListenerDelegate: XPCListenerDelegate {
        
    public var endpoint: NSXPCListenerEndpoint {
        get {
            return listener.endpoint
        }
    }
    
    public init(interface: Protocol) {
        super.init(mode: .anonymous, interface: interface)
    }

}


// Connection/proxy classes
public protocol XPCServiceProxyProtocol : class {
    associatedtype Service
    
    var proxy: Service { get }
    
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


public class XPCServiceProxy<Proxy>: XPCServiceProxyProtocol {
        
    private var serviceName: String
    private var `protocol`: Protocol
    
    private var connection: NSXPCConnection
    private weak var delegate: XPCServiceProxyDelegateProtocol?
    
    private lazy var remoteProxy: Proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.delegate?.connectionError(error: error)
        } as! Proxy
    
    public var proxy: Proxy {
        get {
            return remoteProxy
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
