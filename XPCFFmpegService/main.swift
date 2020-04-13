import Foundation
import XPCServiceFramework
import XPCFFmpegServiceFramework


// The service delegate must be created and remain active until the service is terminated
let serviceDelegate = XPCFFmpegInvokeService()
serviceDelegate.resume()

