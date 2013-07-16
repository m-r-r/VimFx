{ getPref
, getDefaultPref
} = require 'prefs'

{ classes: Cc, interfaces: Ci, utils: Cu } = Components

HTMLInputElement    = Ci.nsIDOMHTMLInputElement
HTMLTextAreaElement = Ci.nsIDOMHTMLTextAreaElement
HTMLSelectElement   = Ci.nsIDOMHTMLSelectElement
XULDocument         = Ci.nsIDOMXULDocument
XULElement          = Ci.nsIDOMXULElement
HTMLDocument        = Ci.nsIDOMHTMLDocument
HTMLElement         = Ci.nsIDOMHTMLElement
Window              = Ci.nsIDOMWindow
ChromeWindow        = Ci.nsIDOMChromeWindow

_sss  = Cc["@mozilla.org/content/style-sheet-service;1"].getService(Ci.nsIStyleSheetService)
_clip = Cc["@mozilla.org/widget/clipboard;1"].getService(Ci.nsIClipboard)

class Bucket
  constructor: (@idFunc, @newFunc) ->
    @bucket = {}

  get: (obj) ->
    id = @idFunc(obj)
    if container = @bucket[id]
      return container
    else
      return @bucket[id] = @newFunc(obj)

  forget: (obj) ->
    delete @bucket[id] if id = @idFunc(obj)

# Returns the `window` from the currently active tab.
getCurrentTabWindow = (event) ->
  if window = getEventWindow(event)
    if rootWindow = getRootWindow(window)
      return rootWindow.gBrowser.selectedTab.linkedBrowser.contentWindow

# Returns the window associated with the event
getEventWindow = (event) ->
  if event.originalTarget instanceof Window
    return event.originalTarget
  else
    doc = event.originalTarget.ownerDocument or event.originalTarget
    if doc instanceof HTMLDocument or doc instanceof XULDocument
      return doc.defaultView

getEventRootWindow = (event) ->
  if window = getEventWindow(event)
    return getRootWindow(window)

getEventTabBrowser = (event) ->
  cw.gBrowser if cw = getEventRootWindow(event)

getRootWindow = (window) ->
  return window.QueryInterface(Ci.nsIInterfaceRequestor)
               .getInterface(Ci.nsIWebNavigation)
               .QueryInterface(Ci.nsIDocShellTreeItem)
               .rootTreeItem
               .QueryInterface(Ci.nsIInterfaceRequestor)
               .getInterface(Window)

isTextInputElement = (element) ->
  return element instanceof HTMLInputElement or \
         element instanceof HTMLTextAreaElement

isElementEditable = (element) ->
  return element.isContentEditable or \
         element instanceof HTMLInputElement or \
         element instanceof HTMLTextAreaElement or \
         element instanceof HTMLSelectElement or \
         element.getAttribute('g_editable') == 'true' or \
         element.getAttribute('contenteditable')?.toLowerCase() == 'true' or \
         element.ownerDocument?.designMode?.toLowerCase() == 'on'

getWindowId = (window) ->
  return window.QueryInterface(Components.interfaces.nsIInterfaceRequestor)
               .getInterface(Components.interfaces.nsIDOMWindowUtils)
               .outerWindowID

getSessionStore = ->
  Cc["@mozilla.org/browser/sessionstore;1"].getService(Ci.nsISessionStore);

# Function that returns a URI to the css file that's part of the extension
cssUri = do ->
  (name) ->
    baseURI = Services.io.newURI(__SCRIPT_URI_SPEC__, null, null)
    uri = Services.io.newURI("resources/#{ name }.css", null, baseURI)
    return uri

# Loads the css identified by the name in the StyleSheetService as User Stylesheet
# The stylesheet is then appended to every document, but it can be overwritten by
# any user css
loadCss = (name) ->
  uri = cssUri(name)
  if !_sss.sheetRegistered(uri, _sss.AGENT_SHEET)
    _sss.loadAndRegisterSheet(uri, _sss.AGENT_SHEET)

  unload ->
    _sss.unregisterSheet(uri, _sss.AGENT_SHEET)

# Simulate mouse click with full chain of event
# Copied from Vimium codebase
simulateClick = (element, modifiers) ->
  document = element.ownerDocument
  window = document.defaultView
  modifiers ||= {}

  eventSequence = ["mouseover", "mousedown", "mouseup", "click"]
  for event in eventSequence
    mouseEvent = document.createEvent("MouseEvents")
    mouseEvent.initMouseEvent(event, true, true, window, 1, 0, 0, 0, 0, modifiers.ctrlKey, false, false,
        modifiers.metaKey, 0, null)
    # Debugging note: Firefox will not execute the element's default action if we dispatch this click event,
    # but Webkit will. Dispatching a click on an input box does not seem to focus it; we do that separately
    element.dispatchEvent(mouseEvent)

# Write a string into system clipboard
writeToClipboard = (window, text) ->
  str = Cc["@mozilla.org/supports-string;1"].createInstance(Ci.nsISupportsString);
  str.data = text

  trans = Cc["@mozilla.org/widget/transferable;1"].createInstance(Ci.nsITransferable);

  if trans.init
    privacyContext = window.QueryInterface(Ci.nsIInterfaceRequestor)
      .getInterface(Ci.nsIWebNavigation)
      .QueryInterface(Ci.nsILoadContext)
    trans.init(privacyContext)

  trans.addDataFlavor("text/unicode");
  trans.setTransferData("text/unicode", str, text.length * 2)

  _clip.setData(trans, null, Ci.nsIClipboard.kGlobalClipboard)

# Write a string into system clipboard
readFromClipboard = (window) ->
  trans = Cc["@mozilla.org/widget/transferable;1"].createInstance(Ci.nsITransferable)

  if trans.init
    privacyContext = window.QueryInterface(Ci.nsIInterfaceRequestor)
      .getInterface(Ci.nsIWebNavigation)
      .QueryInterface(Ci.nsILoadContext);
    trans.init(privacyContext);

  trans.addDataFlavor("text/unicode");

  _clip.getData(trans, Ci.nsIClipboard.kGlobalClipboard)

  str = {}
  strLength = {}

  trans.getTransferData("text/unicode", str, strLength)

  if str
    str = str.value.QueryInterface(Ci.nsISupportsString)
    return str.data.substring(0, strLength.value / 2)

  return undefined

# Executes function `func` and mearues how much time it took
timeIt = (func, msg) ->
  start = new Date().getTime()
  result = func()
  end = new Date().getTime()

  console.log(msg, end - start)
  return result

# Checks if the string provided matches one of the black list entries
# `blackList`: comma/space separated list of URLs with wildcards (* and !)
isBlacklisted = (str, blackList) ->
  for rule in blackList.split(/[\s,]+/)
    rule = rule.replace(/\*/g, '.*').replace(/\!/g, '.')
    if str.match new RegExp("^#{ rule }$")
      return true

  return false

# Gets VimFx verions. AddonManager only provides async API to access addon data, so it's a bit tricky...
getVersion = do ->
  version = null

  if version == null
    scope = {}
    addonId = getPref('addon_id')
    Cu.import("resource://gre/modules/AddonManager.jsm", scope)
    scope.AddonManager.getAddonByID addonId, (addon) -> version = addon.version

  return ->
    return version

# Simulate smooth scrolling
smoothScroll = (window, dx, dy, msecs) ->
  if msecs <= 0 || !Services.prefs.getBoolPref('general.smoothScroll')
    window.scrollBy(dx, dy)
  else
    # Callback
    fn = (_x, _y) ->
      window.scrollBy(_x, _y)
    # Number of steps
    delta = 10
    l = Math.round(msecs / delta)
    while l > 0
      x = Math.round(dx / l)
      y = Math.round(dy / l)
      dx -= x
      dy -= y

      l -= 1
      window.setTimeout(fn, l * delta, x, y)

parseHTML = (document, html) ->
  parser = Cc["@mozilla.org/parserutils;1"].getService(Ci.nsIParserUtils)
  flags = parser.SanitizerAllowStyle
  return parser.parseFragment(html, flags, false, null, document.documentElement)

# Uses nsIIOService to parse a string as a URL and find out if it is a URL
isURL = (str) ->
  try
    url = Cc["@mozilla.org/network/io-service;1"]
      .getService(Ci.nsIIOService)
      .newURI(str, null, null)
      .QueryInterface(Ci.nsIURL)
    return true
  catch err
    return false

# Use Firefox services to search for a given string
browserSearchSubmission = (str) ->
  ss = Cc["@mozilla.org/browser/search-service;1"]
    .getService(Ci.nsIBrowserSearchService)

  engine = ss.currentEngine or ss.defaultEngine
  return engine.getSubmission(str, null)

# Get hint characters, convert them to lower case and fall back
# to default hint characters if there are less than 3 chars
getHintChars = do ->
  # Remove duplicate characters from string (case insensitive)
  removeDuplicateCharacters = (str) ->
    seen = {}
    return str.toLowerCase()
              .split('')
              .filter((char) -> if seen[char] then false else (seen[char] = true))
              .join('')

  return ->
    hintChars = removeDuplicateCharacters(getPref('hint_chars'))
    if hintChars.length < 3
      hintChars = getDefaultPref('hint_chars')

    return hintChars

exports.Bucket                  = Bucket
exports.getCurrentTabWindow     = getCurrentTabWindow
exports.getEventWindow          = getEventWindow
exports.getEventRootWindow      = getEventRootWindow
exports.getEventTabBrowser      = getEventTabBrowser

exports.getWindowId             = getWindowId
exports.getRootWindow           = getRootWindow
exports.isTextInputElement      = isTextInputElement
exports.isElementEditable       = isElementEditable
exports.getSessionStore         = getSessionStore

exports.loadCss                 = loadCss

exports.simulateClick           = simulateClick
exports.smoothScroll            = smoothScroll
exports.readFromClipboard       = readFromClipboard
exports.writeToClipboard        = writeToClipboard
exports.timeIt                  = timeIt
exports.isBlacklisted           = isBlacklisted
exports.getVersion              = getVersion
exports.parseHTML               = parseHTML
exports.isURL                   = isURL
exports.browserSearchSubmission = browserSearchSubmission
exports.getHintChars            = getHintChars
