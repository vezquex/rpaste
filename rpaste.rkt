#lang racket/base

(require racket/bool
         racket/date
         racket/exn
         racket/function
         racket/list
         racket/match
         racket/port
         db
         openssl/sha1
         net/url
         web-server/web-server
         web-server/http
         web-server/servlet-env
         web-server/templates)

(define schema-version 2)

(define db-conn
  (virtual-connection
   (thunk (sqlite3-connect #:database (build-path (find-system-path 'home-dir)
                                                  (format "rpaste~a.sqlite3" schema-version))
                           #:mode 'create))))

(define site-title "Pastes hosted by rpaste")

(query-exec db-conn #<<END
CREATE TABLE IF NOT EXISTS Pastes
  ("id" INTEGER PRIMARY KEY  AUTOINCREMENT  NOT NULL,
   "key" TEXT NOT NULL  UNIQUE,
   "paste" BLOB NOT NULL,
   "timestamp" INTEGER NOT NULL)
END
            )

(define style #<<END
body {
  font-family: mono;
}

END
  )
(define form-style #<<END
html, body, #container, form {
  height: 100%;
  margin: 0;
}

form {
  display: flex;
  flex-direction: column;
}

#container textarea {
  flex-grow: 1;
}

#container button {
  width: 100%;
}
END
  )

(define (start req)
  (match (request-method req)
    [#"HEAD" (make-head (start (struct-copy request req [method #"GET"])))]
    [#"GET" (route-get req)]
    [#"POST" (make-paste req)]
    [m (mk-bad (format "Method ~a not allowed." m) #:code 405 #:message #"Method Not Allowed")]))

(define (route-get req)
  (match (map path/param-path (url-path (request-uri req)))
    [(or (? null?)
         (list "" ...)
         (list "list"))
     (list-pastes req)]
    [(list "form") (paste-form req)]
    [(list-rest "static" paths) (send-static req)]
    [_ (show-paste req)]))

(define (send-static req)
  (define res #f)
  (with-handlers ([exn:fail:filesystem? (λ (ex) (set! res (mk-bad
                                                           (exn->string ex)
                                                           #:code 404
                                                           #:message #"Not Found")))])
    (define pth (apply build-path (map path/param-path (url-path (request-uri req)))))
    (displayln pth)
    (define ip (open-input-file pth))
    (set! res (mk-gud (curry copy-port ip) #:mime #"text/css"))
    (displayln res))
  res)

(define (make-head res)
  (struct-copy response res [output (λ (op) (void))]))

(define (mk-bad txt #:code [code 404] #:message [msg #"Not found"] #:mime [mime #"text/plain"])
  (response/output (λ (op)
                    (write-string txt op)
                    (void))
                  #:code code
                  #:message msg
                  #:mime-type mime))

(define (mk-gud fn #:mime [mime #"text/plain; charset=utf-8"])
  (response/output fn #:mime-type mime))

(define (epoch->rfc2822 epoch)
  (parameterize ([date-display-format 'rfc2822])
    (date->string (seconds->date epoch #f) #t)))

(define (get-requested-host req)
  (define h (headers-assq #"Host" (request-headers/raw req)))
  (if h
      (header-value h)
      (format "~a:~a" (request-host-ip req) (request-host-port req))))

(define (list-pastes req)
  (define rows (query-rows db-conn "SELECT key, timestamp FROM Pastes ORDER BY timestamp DESC"))
  (define site-address (get-requested-host req))
  (response/full
   200 #"Okay"
   (current-seconds) TEXT/HTML-MIME-TYPE
   empty
   (list (string->bytes/utf-8 (include-template "templates/homepage.html")))))

(define (paste-form req)
  (response/full
   200 #"Okay"
   (current-seconds) TEXT/HTML-MIME-TYPE
   empty
   (list (string->bytes/utf-8 (include-template "templates/form.html")))))

(define (show-paste req)
  (define p (map path/param-path (url-path (request-uri req))))
  (if (null? p)
      (mk-bad "Not found [no paste specified with /your_paste_here] :(")
      (let ([rows (query-rows db-conn
                              "SELECT paste FROM Pastes WHERE key = ?"
                              (car p))])
        (if (null? rows)
            (mk-bad (format "No paste with key [~a] :(" (car p)))
            (mk-gud (λ (op) (write-bytes (vector-ref (car rows) 0) op) (void)))))))

(define (make-paste req)
  (define raw (request-bindings/raw req))
  (define pf (implies raw (bindings-assq #"p" raw)))
  (if (binding:form? pf)
      (let* ([data (binding:form-value pf)]
             [hash (sha1 (open-input-bytes data))])
        (query-exec db-conn
                    "INSERT OR IGNORE INTO Pastes (key, paste, timestamp) VALUES (?, ?, ?)"
                    hash data (current-seconds))
        (if (and raw (bindings-assq #"redirect" raw))
            (redirect-to (format "/~a" hash))
        (mk-gud (λ (op) (write-string (string-append hash "\n") op) (void)))))
      (response/output (λ (op) (write-string "Bad request. Need payload p=...") (void))
                       #:code 400
                       #:message #"Bad request")))

(serve/servlet start
               #:stateless? #t
               #:listen-ip #f
               #:port 8080
               #:servlet-path "/"
               #:servlet-regexp #rx""
               #:command-line? #t
               #:server-root-path ".")