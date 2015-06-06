$Cypress.Cy = do ($Cypress, _, Backbone) ->

  class $Cy
    ## does this need to be moved
    ## to an instance property?
    sync: {}

    constructor: (@Cypress, specWindow) ->
      @queue = []
      @defaults()
      @listeners()

      specWindow.cy = @

    initialize: (obj) ->
      @defaults()

      {@$remoteIframe, @config} = obj

      @$remoteIframe.on "load", =>
        @urlChanged()
        @pageLoading(false)

        ## we reapply window listeners on load even though we
        ## applied them already during onBeforeLoad. the reason
        ## is that after load javascript has finished being evaluated
        ## and we may need to override things like alert + confirm again
        @bindWindowListeners @$remoteIframe.prop("contentWindow")
        @isReady(true, "load")

      ## anytime initialize is called we immediately
      ## set cy to be ready to invoke commands
      ## this prevents a bug where we go into not
      ## ready mode due to the unload event when
      ## our tests are re-run
      @isReady(true, "initialize")

    defaults: ->
      @props = {}

      return @

    listeners: ->
      @listenTo @Cypress, "initialize", (obj, bool) =>
        @initialize(obj, bool)

      ## why arent we listening to "defaults" here?
      ## instead we are manually hard coding them
      @listenTo @Cypress, "stop",       => @stop()
      @listenTo @Cypress, "restore",    => @restore()
      @listenTo @Cypress, "abort",      => @abort()

    abort: ->
      @$remoteIframe?.off("submit beforeunload unload load hashchange")
      @isReady(false, "abort")
      @prop("runnable")?.clearTimeout()

      promise = @prop("promise")
      promise?.cancel()

      ## ready can potentially be cancellable
      ## so we need cancel it (if it is)
      ready = @prop("ready")
      if ready and readyPromise = ready.promise
        if readyPromise.isCancellable()
          readyPromise.cancel()

      Promise.resolve(promise)

    stop: ->
      delete window.cy

      @Cypress.cy = null

    restore: ->
      ## if our index is above 0 but is below the queue.length
      ## then we know we've ended early due to a done() and
      ## we should throw a very specific error message
      index = @prop("index")
      @endedEarlyErr() if index > 0 and index < @queue.length

      @clearTimeout @prop("runId")
      @clearTimeout @prop("timerId")

      @prop("angularCancelTimeout")?()

      ## reset the queue to an empty array
      @queue = []

      ## remove any outstanding groups
      ## for any open hooks and runnables
      @group(false)
      @group(false)

      ## remove any event listeners
      @off()

      ## removes any registered props from the
      ## instance
      @defaults()

    prop: (key, val) ->
      if arguments.length is 1
        @props[key]
      else
        @props[key] = val

    ## global options applicable to all cy instances
    ## and restores
    options: (options = {}) ->

    _eventHasReturnValue: (e) ->
      val = e.originalEvent.returnValue

      ## return false if val is an empty string
      ## of if its undinefed
      return false if val is "" or _.isUndefined(val)

      ## else return true
      return true

    isReady: (bool = true, event) ->
      if bool
        ## we set recentlyReady to true
        ## so we dont accidently set isReady
        ## back to false in between commands
        ## which are async
        @log "Ready due to: #{event}", "success"
        @prop("recentlyReady", true)

        if ready = @prop("ready")
          if ready.promise.isPending()
            ready.promise.then =>
              @trigger "ready", true

              ## prevent accidential chaining
              ## .this after isReady resolves
              return null

        return ready?.resolve()

      ## if we already have a ready object and
      ## its state is pending just leave it be
      ## and dont touch it
      return if @prop("ready") and @prop("ready").promise.isPending()

      ## else set it to a deferred object
      @log "No longer ready due to: #{event}", "warning"

      @trigger "ready", false

      @prop "ready", Promise.pending()

    run: ->
      ## start at 0 index if we dont have one
      index = @prop("index") ? @prop("index", 0)

      queue = @queue[index]

      runnable = @prop("runnable")

      @group(runnable.group)

      ## if we're at the very end
      if not queue

        ## trigger end event
        @trigger("end")

        ## and we should have a next property which
        ## holds mocha's .then callback fn
        if next = @prop("next")
          next()
          @prop("next", null)

        return @

      ## store the previous timeout
      prevTimeout = @_timeout()

      ## prior to running set the runnables
      ## timeout to 30s. this is useful
      ## because we may have to wait to begin
      ## running such as the case in angular
      @_timeout(30000)

      run = =>
        ## bail if we've changed runnables by the
        ## time this resolves
        return if @prop("runnable") isnt runnable

        ## reset the timeout to what it used to be
        @_timeout(prevTimeout)

        @trigger "command:start", queue

        promise = @set(queue, @queue[index - 1], @queue[index + 1]).then =>
          ## each successful command invocation should
          ## always reset the timeout for the current runnable
          ## unless it already has a state.  if it has a state
          ## and we reset the timeout again, it will always
          ## cause a timeout later no matter what.  by this time
          ## mocha expects the test to be done
          @_timeout(prevTimeout) if not runnable.state

          ## mutate index by incrementing it
          ## this allows us to keep the proper index
          ## in between different hooks like before + beforeEach
          ## else run will be called again and index would start
          ## over at 0
          @prop("index", index += 1)

          @trigger "command:end", queue

          @defer @run

          ## must have this empty return here else we end up creating
          ## additional .then callbacks due to bluebird chaining
          return null

        .catch Promise.CancellationError, (err) =>
          @cancel(err)

          ## need to signify we're done our promise here
          ## so we cannot chain off of it, or have bluebird
          ## accidentally chain off of the return value
          return err

        .catch (err) =>
          @fail(err)

          ## reset the nestedIndex back to null
          @prop("nestedIndex", null)

          ## also reset recentlyReady back to null
          @prop("recentlyReady", null)

          return err
        ## signify we are at the end of the chain and do not
        ## continue chaining anymore
        # promise.done()

        @prop "promise", promise

        @trigger "set", queue

      ## automatically defer running each command in succession
      ## so each command is async
      @defer ->
        angular = @sync.window().angular

        if angular and angular.getTestability
          run            = _.bind(run, @)

          root           = @$("[ng-app]").get(0)
          $timeout       = angular.element(root).injector().get("$timeout")
          angularPromise = $timeout =>
            angular.getTestability(root).whenStable(run)
            @prop "angularCancelTimeout", null
          , 20

          @prop "angularCancelTimeout", ->
            $timeout.cancel(angularPromise)

          return null
        else
          run()

    clearTimeout: (id) ->
      clearImmediate(id) if id
      return @

    # get: (name) ->
    #   alias = @aliases[name]
    #   return alias unless _.isUndefined(alias)

    #   ## instead of returning a function here and setting this
    #   ## invoke property, we should just convert this to a deferred
    #   ## and then during the actual save we should find out anystanding
    #   ## 'get' promises that match the name and then resolve them.
    #   ## the problem with this is we still need to run this anonymous
    #   ## function to check to see if we have an alias by that name
    #   ## else our alias will never resolve (if save is never called
    #   ## by this name argument)
    #   fn = =>
    #     @aliases[name] or
    #       @throwErr("No alias was found by the name: #{name}")
    #   fn._invokeImmediately = true
    #   fn

    _storeHref: ->
      ## we are using href and stripping out the hash because
      ## hash changes do not cause full page refreshes
      ## however, i believe this will completely barf when
      ## JS users are using pushstate since there is no hash
      ## TODO. need to listen to pushstate events here which
      ## will act as the isReady() the same way load events do
      location = @sync.location({log: false})
      @prop "href", location.href.replace(location.hash, "")

    _hrefChanged: ->
      location = @sync.location({log: false})
      console.log "command is", @prop("current").name, "href is", @prop("href"), "location href is", location.href
      @prop("href") isnt location.href.replace(location.hash, "")

    set: (obj, prev, next) ->
      obj.prev = prev
      obj.next = next

      @prop("current", obj)

      @invoke2(obj)

    invoke2: (obj, args...) ->
      promise = if @prop("ready")
        Promise.resolve @prop("ready").promise
      else
        Promise.resolve()

      promise.cancellable().then =>
        @trigger "invoke:start", obj

        @log obj

        ## store our current href before invoking the next command
        @_storeHref()

        @prop "nestedIndex", @prop("index")

        ## allow the invoked arguments to be overridden by
        ## passing them in explicitly
        ## else just use the arguments the command was
        ## originally created with
        if args.length then args else obj.args

      ## allow promises to be used in the arguments
      ## and wait until they're all resolved
      .all(args)

      .then (args) =>
        ## if the first argument is a function and it has an _invokeImmediately
        ## property that means we are supposed to immediately invoke
        ## it and use its return value as the argument to our
        ## current command object
        if _.isFunction(args[0]) and args[0]._invokeImmediately
          args[0] = args[0].call(@)

        ## rewrap all functions by checking
        ## the chainer id before running its fn
        @_checkForNewChain(obj.chainerId)

        ## we cannot pass our cypress instance or our chainer
        ## back into bluebird else it will create a thenable
        ## which is never resolved
        ret = obj.fn.apply(obj.ctx, args)
        if (ret is @ or ret is @chain()) then null else ret

      .then (subject, options = {}) =>
        obj.subject = subject

        ## trigger an event here so we know our
        ## command has been successfully applied
        ## and we've potentially altered the subject
        @trigger "invoke:subject", subject, obj

        # if we havent become recently ready and unless we've
        # explicitly disabled checking for location changes
        # and if our href has changed in between running the commands then
        # then we're no longer ready to proceed with the next command
        # if @prop("recentlyReady") is null
        #   if @_hrefChanged()
        #     debugger
        #     @isReady(false, "href changed")

        # @onInvokeEnd(subject)

        ## reset the nestedIndex back to null
        @prop("nestedIndex", null)

        ## also reset recentlyReady back to null
        @prop("recentlyReady", null)

        ## return the prop subject
        @prop("subject", subject)

        @trigger "invoke:end", obj

        ## we must look back at the ready property
        ## at the end of resolving our command because
        ## its possible it has become "unready" such
        ## as beforeunload firing. in that case before
        ## resolving we need to ensure it finishes first
        if ready = @prop("ready")
          if ready.promise.isPending()
            return ready.promise.return(subject).catch (err) ->

        return subject

    cancel: (err) ->
      obj = @prop("current")
      @log {name: "Cancelled: #{obj.name}", args: err.message}, "danger"
      @trigger "cancel", obj

    _contains: ($el) ->
      doc = @sync.document().get(0)

      contains = (el) ->
        $.contains(doc, el)

      ## either see if the raw element itself
      ## is contained in the document
      if _.isElement($el)
        contains($el)
      else
        ## or all the elements in the collection
        _.all $el.toArray(), contains

    _getRemoteJQuery: ->
      if opt = @Cypress.option("jQuery")
        return opt
      else
        @sync.window().$

    _checkForNewChain: (chainerId) ->
      ## dont do anything if this isnt even defined
      return if _.isUndefined(chainerId)

      ## if we dont have a current chainerId
      ## then set one
      if not id = @prop("chainerId")
        @prop("chainerId", chainerId)
      else
        ## else if we have one currently and
        ## it doesnt match then nuke our subject
        ## since we've started a new chain
        ## and reset our chainerId
        if id isnt chainerId
          @prop("chainerId", chainerId)
          @prop("subject", null)

    ## the command method is useful for synchronously
    ## calling another command but wrapping it in a
    ## promise
    command: (name, args...) ->
      Promise.resolve @sync[name].apply(@, args)

    defer: (fn) ->
      @clearTimeout(@prop("timerId"))
      # @prop "timerId", _.defer _.bind(fn, @)
      @prop "timerId", setImmediate _.bind(fn, @)

    hook: (name) ->
      @prop("hookName", name)

      return if not @prop("inspect")

      return console.groupEnd() if not name

      console.group(name)

    group: (name) ->
      ## bail if we're not in inspect mode
      return if not @prop("inspect") or _.isUndefined(name)

      ## end the group if name is explicitly false
      return console.groupEnd() if name is false

      ## bail if we already have a _group set
      return if @_group

      ## set the _group
      @_group = name

      ## start a group by the name
      console.group(name)

    ## returns the current chain so you can continue
    ## chaining off of cy without breaking the current
    ## subject
    chain: ->
      @prop("chain")

    enqueue: (key, fn, args, type, chainerId) ->
      @clearTimeout @prop("runId")

      obj = {name: key, ctx: @, fn: fn, args: args, type: type, chainerId: chainerId}

      @trigger "enqueue", obj
      @Cypress.trigger "enqueue", obj

      @_insert(obj)

    _insert: (obj) ->
      ## if we have a nestedIndex it means we're processing
      ## nested commands and need to splice them into the
      ## index past the current index as opposed to
      ## pushing them to the end we also dont want to
      ## reset the run defer because splicing means we're
      ## already in a run loop and dont want to create another!
      ## we also reset the .next property to properly reference
      ## our new obj

      ## we had a bug that would bomb on custom commands when it was the
      ## first command. this was due to nestedIndex being undefined at that
      ## time. so we have to ensure to check that its any kind of number (even 0)
      ## in order to know to splice into the existing array.
      ## we simplified

      nestedIndex = @prop("nestedIndex")

      ## if this is a number then we know
      ## we're about to splice this into our queue
      ## and need to reset next + increment the index
      if _.isNumber(nestedIndex)
        @queue[nestedIndex].next = obj
        @prop("nestedIndex", nestedIndex += 1)

      ## we look at whether or not nestedIndex is a number, because if it
      ## is then we need to splice inside of our queue, else just push
      ## it onto the end of the queu
      index = if _.isNumber(nestedIndex) then nestedIndex else @queue.length

      @queue.splice(index, 0, obj)

      ## if nestedIndex is either undefined or 0
      ## then we know we're processing regular commands
      ## and not splicing in the middle of our queue
      if not nestedIndex
        @prop "runId", @defer(@run)

      return @

    setRunnable: (runnable, hookName) ->
      ## think about moving the cy.config object
      ## to Cypress so it doesnt need to be reset.
      ## also our options are "global" whereas
      ## options on @cy are local to that specific
      ## test run
      runnable.startedAt = new Date

      if @config and _.isFinite(timeout = @config("commandTimeout"))
        runnable.timeout timeout

      @hook(hookName)
      @prop("runnable", runnable)

      return @

    $: (selector, context) ->
      context ?= @sync.document()
      new $.fn.init selector, context

    _: _

    Promise: Promise

    _.extend $Cy.prototype, Backbone.Events

    @extend = (obj) ->
      _.extend @prototype, obj

    @set = (Cypress, runnable, hookName) ->
      return if not cy = Cypress.cy

      cy.setRunnable(runnable, hookName)

    @create = (Cypress, specWindow) ->
      ## clear out existing listeners
      ## if we already exist!
      if existing = Cypress.cy
        existing.stopListening()

      Cypress.cy = window.cy = new $Cy Cypress, specWindow

  return $Cy