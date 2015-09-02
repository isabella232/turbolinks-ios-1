import WebKit

let TLVisitErrorDomain = "com.basecamp.Turbolinks"

protocol TLVisitDelegate: class {
    func visitDidStart(visit: TLVisit)
    func visitDidFail(visit: TLVisit)
    func visitDidFinish(visit: TLVisit)

    func visitWillIssueRequest(visit: TLVisit)
    func visit(visit: TLVisit, didFailRequestWithError error: NSError)
    func visit(visit: TLVisit, didFailRequestWithStatusCode statusCode: Int)
    func visit(visit: TLVisit, didCompleteRequestWithResponse response: String)
    func visitDidCompleteWebViewLoad(visit: TLVisit)
    func visitDidFinishRequest(visit: TLVisit)
}

enum TLVisitDirection: String {
    case Forward = "Forward"
    case Backward = "Backward"
}

class TLVisit: NSObject {
    var visitable: TLVisitable
    var direction: TLVisitDirection
    var webView: TLWebView
    weak var delegate: TLVisitDelegate?
    
    override var description: String {
        return "<\(self.dynamicType), location: \(location)>"
    }
    
    var location: NSURL? {
        return visitable.location
    }
   
    enum State: String, Printable {
        case Initialized = "Initialized"
        case Started = "Started"
        case Completed = "Completed"
        case Canceled = "Canceled"
        
        var description: String {
            return rawValue
        }
    }
    
    var requestState: State = .Initialized
    var navigationState: State = .Started

    var finished: Bool = false

    var completed: Bool {
        return finished && !canceled
    }
    
    var canceled: Bool {
        return finished && (requestState == .Canceled || navigationState == .Canceled)
    }
    
    var failed: Bool = false

    var succeeded: Bool {
        return completed && !failed
    }
    
    init(visitable: TLVisitable, direction: TLVisitDirection, webView: TLWebView) {
        self.visitable = visitable
        self.direction = direction
        self.webView = webView
    }
    
    func cancel() {
        NSLog("\(self) cancel()")

        cancelNavigation()
        cancelRequest()
        finish()
    }

    func fail() {
        NSLog("\(self) fail(), finished? \(finished), failed? \(failed)")

        if !finished && !failed {
            failed = true
            delegate?.visitDidFail(self)
            finish()
        }
    }

    func finish() {
        NSLog("\(self) finish(), finished? \(finished)")

        if !finished {
            finished = true
            completeRequest()
            completeNavigation()
            delegate?.visitDidFinish(self)
        }
    }
    
    func startRequest() {
        NSLog("\(self) startRequest(), requestState: \(requestState)")

        if requestState == .Initialized {
            requestState = .Started
            delegate?.visitDidStart(self)
            delegate?.visitWillIssueRequest(self)
            issueRequest()
        }
    }
    
    func completeRequest() {
        NSLog("\(self) completeRequest(), requestState: \(requestState)")

        if requestState == .Started {
            requestState = .Completed
            delegate?.visitDidFinishRequest(self)
        }
    }
    
    func cancelRequest() {
        NSLog("\(self) cancelRequest(), requestState: \(requestState)")

        if requestState == .Started {
            requestState = .Canceled
            abortRequest()
            delegate?.visitDidFinishRequest(self)
            finish()
        }
    }
    
    func completeNavigation() {
        NSLog("\(self) completeNavigation(), navigationState: \(navigationState)")

        if navigationState == .Started {
            navigationState = .Completed
            navigationLock.unlock()
        }
    }
    
    func cancelNavigation() {
        NSLog("\(self) cancelNavigation(), navigationState: \(navigationState)")

        if navigationState == .Started {
            navigationState = .Canceled
            cancelRequest()
            finish()
        }
    }
    
    private func issueRequest() {}
    private func abortRequest() {}
    
    private lazy var navigationLock: TLLock = {
        return TLLock(queue: dispatch_get_main_queue())
    }()
    
    private func afterNavigationCompletion(callback: () -> ()) {
        navigationLock.afterUnlock(callback)
    }
}

class TLWebViewVisit: TLVisit, WKNavigationDelegate {
    lazy var request: NSURLRequest? = {
        if let location = self.location {
            return NSURLRequest(URL: location)
        } else {
            return nil
        }
    }()

    override private func issueRequest() {
        if let request = self.request {
            webView.navigationDelegate = self
            webView.loadRequest(request)
        }
    }
    
    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        webView.navigationDelegate = nil
        delegate?.visitDidCompleteWebViewLoad(self)
        finish()
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse, decisionHandler: (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? NSHTTPURLResponse {
            if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                decisionHandler(.Allow)
            } else {
                decisionHandler(.Cancel)
                delegate?.visit(self, didFailRequestWithStatusCode: httpResponse.statusCode)
                fail()
            }
        }
    }

    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: NSError) {
        if !failed {
            delegate?.visit(self, didFailRequestWithError: error)
            fail()
        }
    }

    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        if !failed {
            delegate?.visit(self, didFailRequestWithError: error)
            fail()
        }
    }
}

class TLTurbolinksVisit: TLVisit, TLRequestDelegate {
    override private func issueRequest() {
        if let location = self.location {
            webView.requestDelegate = self
            webView.issueRequestForLocation(location)
        }
    }
    
    override private func abortRequest() {
        webView.abortCurrentRequest()
    }

    // TLRequestDelegate

    func webView(webView: TLWebView, didReceiveResponse response: String) {
        afterNavigationCompletion {
            self.delegate?.visit(self, didCompleteRequestWithResponse: response)
            self.completeRequest()
        }
    }

    func webView(webView: TLWebView, requestDidFailWithStatusCode statusCode: Int?) {
        afterNavigationCompletion {
            if statusCode == nil {
                let error = NSError(domain: TLVisitErrorDomain, code: 0, userInfo: nil)
                self.delegate?.visit(self, didFailRequestWithError: error)
            } else {
                self.delegate?.visit(self, didFailRequestWithStatusCode: statusCode!)
            }

            self.fail()
        }
    }
}
