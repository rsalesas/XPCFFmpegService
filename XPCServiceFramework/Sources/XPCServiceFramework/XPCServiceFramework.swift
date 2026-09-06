import Foundation


// Creates a listener delegate for the specified interface/object and mode
open class XPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    
    fileprivate enum ListenerMode {
        case service
        case anonymous
    }
    
    
    fileprivate let listener: NSXPCListener
    
    private let interface: NSXPCInterface
    
    fileprivate init(mode: ListenerMode, interface: NSXPCInterface) {
        self.interface = interface
        self.listener = (mode == .service) ? NSXPCListener.service() : NSXPCListener.anonymous()
        super.init()
        
        self.listener.delegate = self
    }
    
    fileprivate convenience init(mode: ListenerMode, interface: Protocol) {
        self.init(mode: mode, interface: NSXPCInterface(with: interface))
    }
    
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = interface
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
open class XPCServiceListenerDelegate: XPCListenerDelegate {
        
    public init(interface: NSXPCInterface) {
        super.init(mode: .service, interface: interface)
    }
    
    public convenience init(interface: Protocol) {
        self.init(interface: NSXPCInterface(with: interface))
    }
}


// Creates a anonymous listener for the specified interface/object
open class XPCAnonymousListenerDelegate: XPCListenerDelegate {
        
    public var endpoint: NSXPCListenerEndpoint {
        get {
            return listener.endpoint
        }
    }
    
    public init(interface: NSXPCInterface) {
        super.init(mode: .anonymous, interface: interface)
    }

    public convenience init(interface: Protocol) {
        self.init(interface: NSXPCInterface(with: interface))
    }

}


// Connection/proxy classes
public protocol XPCServiceProxyProtocol : AnyObject {
    associatedtype Service
    
    var proxy: Service { get }
    
    func reconnect()
    
    func resume()
    
    func suspend()

    func invalidate()

}


public protocol XPCServiceProxyDelegateProtocol : AnyObject {

    func interruption()
    
    func invalidation()
    
    func connectionError(error: Error)
    
}


open class XPCServiceProxy<Proxy>: XPCServiceProxyProtocol {
        
    private var serviceName: String
    private var interface: NSXPCInterface
    
    private var connection: NSXPCConnection
    private weak var delegate: XPCServiceProxyDelegateProtocol?
    
    // Resolved against the current connection on every access rather than cached, so that a
    // proxy handed out after reconnect() talks to the new connection instead of the dead one.
    public var proxy: Proxy {
        get {
            return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.delegate?.connectionError(error: error)
                } as! Proxy
        }
    }

    public init(serviceName: String, interface: NSXPCInterface, delegate: XPCServiceProxyDelegateProtocol? = nil) {
        self.serviceName = serviceName
        self.interface = interface
        self.delegate = delegate
        
        connection = XPCServiceProxy.connect(serviceName: serviceName, interface: interface, delegate: delegate)
        
        if self.delegate == nil, self is XPCServiceProxyDelegateProtocol {
            self.delegate = self as? XPCServiceProxyDelegateProtocol
        }
    }
    
    public convenience init(serviceName: String, protocol: Protocol, delegate: XPCServiceProxyDelegateProtocol? = nil) {
        self.init(serviceName: serviceName, interface: NSXPCInterface(with: `protocol`), delegate: delegate)
    }
    
    public func reconnect() {
        connection = XPCServiceProxy.connect(serviceName: self.serviceName, interface: self.interface, delegate: delegate)
    }
    
    private static func connect(serviceName: String, interface: NSXPCInterface, delegate: XPCServiceProxyDelegateProtocol?) -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = interface
        
        connection.interruptionHandler = { [weak delegate] in
            delegate?.interruption()
        }
            
        connection.invalidationHandler =  { [weak delegate] in
            delegate?.invalidation()
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
