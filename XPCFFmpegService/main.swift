import Foundation


// The service delegate must be created and remain active until the service is terminated
let serviceDelegate = XPCFFmpegInvoke()
serviceDelegate.resume()

