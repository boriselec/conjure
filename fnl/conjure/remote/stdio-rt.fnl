(module conjure.remote.stdio-rt
  {autoload {a conjure.aniseed.core
             nvim conjure.aniseed.nvim
             str conjure.aniseed.string
             client conjure.client
             log conjure.log}})

(def- uv vim.loop)

(defn- parse-prompt [s pat]
  (if (s:find pat)
    (values true (s:gsub pat ""))
    (values false s)))

(defn parse-cmd [x]
  (if
    (a.table? x)
    {:cmd (a.first x)
     :args (a.rest x)}

    (a.string? x)
    (parse-cmd (str.split x "%s"))))

(defn- extend-env [vars]
  (->> (a.merge
         (nvim.fn.environ)
         vars)
       (a.kv-pairs)
       (a.map
         (fn [[k v]]
           (.. k "=" v)))))

; This function sets up internal functions before spawning a child
; process to run the repl. It's called by a client to start a repl
; and returns a modified repl table.
(defn start [opts]
  "Starts an external REPL and gives you hooks to send code to it and read
  responses back out. Tying an input to a result is near enough impossible
  through this stdio medium, so it's a best effort.
  * opts.prompt-pattern: Identify result boundaries such as '> '.
  * opts.cmd: Command to run to start the REPL.
  * opts.args: Arguments to pass to the REPL.
  * opts.on-error: Called with an error string when we receive a true error from the process.
  * opts.delay-stderr-ms: If passed, delays the call to on-error for this many milliseconds. This
                          is a workaround for clients like python whose prompt on stderr sometimes
                          arrives before the previous command's output on stdout.
  * opts.on-stray-output: Called with stray output that don't match up to a callback.
  * opts.on-exit: Called on exit with the code and signal."
  (let [stdin (uv.new_pipe false)
        stdout (uv.new_pipe false)
        stderr (uv.new_pipe false)]

    (var repl {:queue []
               :current nil})

    (fn destroy []
      ;; https://teukka.tech/vimloop.html
      (pcall #(stdout:read_stop))
      (pcall #(stderr:read_stop))
      (pcall #(stdout:close))
      (pcall #(stderr:close))
      (pcall #(stdin:close))
      (when repl.handle
        (pcall #(uv.process_kill repl.handle))
        (pcall #(repl.handle:close)))
      nil)

    (fn on-exit [code signal]
      (destroy)
      (client.schedule opts.on-exit code signal))

    (fn next-in-queue []
      (log.dbg "stdio.next-in-queue: # msgs in queue:" (a.count repl.queue))
      (log.dbg "  stdio.next-in-queue: queue:" (a.pr-str repl.queue))
      (log.dbg "  stdio.next-in-queue: current:" (a.pr-str repl.current))
      (let [next-msg (a.first repl.queue)]
        (when next-msg
          (table.remove repl.queue 1)
          (a.assoc repl :current next-msg)
          (log.dbg "  stdio.next-in-queue: send" next-msg.code)
          (stdin:write next-msg.code))))

    (fn on-message [source err chunk]
      (log.dbg "stdio.on-message: receive [source err chunk]" source err chunk)
      (if err
        (do
          (opts.on-error err)
          (destroy))
        (when chunk
          (let [(done? result) (parse-prompt chunk opts.prompt-pattern)
                cb (a.get-in repl [:current :cb] opts.on-stray-output)]
            (log.dbg "  stdio.on-message: opts.prompt-pattern" opts.prompt-pattern)
            (log.dbg "  stdio.on-message: [done? result]" done? result)
            (when cb
              (log.dbg "  stdio.on-message: current:" (a.pr-str repl.current))
              (log.dbg "  stdio.on-message: calling cb [repl.current]")
              (pcall #(cb {source result
                           :done? done?})))
            (when done? ; never gets here because done? is always false
              (a.assoc repl :current nil)
              (next-in-queue))))))

    (fn on-stdout [err chunk]
      (on-message :out err chunk))

    (fn on-stderr [err chunk]
      (if opts.delay-stderr-ms
        (vim.defer_fn #(on-message :err err chunk) opts.delay-stderr-ms)
        (on-message :err err chunk)))

    (fn send [code cb opts]
      (log.dbg "stdio.send called [opts] " (a.pr-str opts))
      (log.dbg "  stdio.send adding task")
      (table.insert
        repl.queue
        {:code code
         :cb (if (a.get opts :batch?)
               (let [msgs []]
                 (fn [msg]
                   (log.dbg "  stdio.send cb for batch?: accumulate " msg)
                   (table.insert msgs msg)
                   (when msg.done?
                     (cb msgs))))
               cb)})
      (log.dbg "  stdio.send calling next-in-queue")
      (next-in-queue)
      nil)

    (fn send-signal [signal]
      (uv.process_kill repl.handle signal)
      nil)

    (let [{: cmd : args} (parse-cmd opts.cmd)
          (handle pid-or-err)
          (uv.spawn cmd {:stdio [stdin stdout stderr]
                         :args args
                         :env (extend-env
                                (a.merge!
                                  ;; Trying to disable custom readline config.
                                  ;; Doesn't work in practice but is probably close?
                                  ;; If you know how, please open a PR!
                                  {:INPUTRC "/dev/null"
                                   :TERM "dumb"}
                                  opts.env))}
                    (client.schedule-wrap on-exit))]
      (if handle
        (do
          (stdout:read_start (client.schedule-wrap on-stdout))
          (stderr:read_start (client.schedule-wrap on-stderr))
          (client.schedule #(opts.on-success))
          (a.merge!
            repl
            {:handle handle
             :pid pid-or-err
             :send send
             :opts opts
             :send-signal send-signal
             :destroy destroy})) ; returns modified repl table
        (do
          (client.schedule #(opts.on-error pid-or-err))
          (destroy))))))
