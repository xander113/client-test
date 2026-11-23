package hub

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"io"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/vmihailenco/msgpack/v5"
	"pot.local/runtime/internal/place"
	"pot.local/runtime/internal/thumb"
)

const maxPNGBytes = 1024 * 1024

type status struct {
	Service string `msgpack:"service"`
	Status  string `msgpack:"status"`
}

type problem struct {
	Message string `msgpack:"message"`
}

type authorizer struct {
	digest [32]byte
	set    bool
}

func authorization(token string) (authorizer, error) {
	if len(token) > 512 || strings.ContainsFunc(token, func(r rune) bool { return r < 33 || r > 126 }) {
		return authorizer{}, errors.New("access tokens must be single printable ASCII values")
	}
	return authorizer{sha256.Sum256([]byte(token)), token != ""}, nil
}

func (a authorizer) accepts(header string) bool {
	prefix, token, ok := strings.Cut(header, " ")
	if !ok || !strings.EqualFold(prefix, "Bearer") || !a.set {
		return false
	}
	supplied := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(a.digest[:], supplied[:]) == 1
}

func authRequired(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	fail(w, http.StatusUnauthorized, "the service denied access")
}

func packed(w http.ResponseWriter, code int, value any) {
	packet, err := msgpack.Marshal(value)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	write(w, code, place.MIME, packet)
}

func fail(w http.ResponseWriter, code int, message string) {
	packed(w, code, problem{message})
}

func write(w http.ResponseWriter, code int, contentType string, data []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_, _ = w.Write(data)
}

func readProject(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	kind, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if kind != place.MIME {
		fail(w, http.StatusUnsupportedMediaType, "send a binary Pot project")
		return nil, false
	}
	body := http.MaxBytesReader(w, r.Body, place.MaxSize)
	defer body.Close()
	packet, err := io.ReadAll(body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			fail(w, http.StatusRequestEntityTooLarge, "project exceeds its size limit")
		} else {
			fail(w, http.StatusBadRequest, "could not read the Pot project")
		}
		return nil, false
	}
	return packet, true
}

type Server struct {
	URL  string
	http *http.Server
	stop context.CancelFunc
	done <-chan struct{}
}

func start(address string, handler http.Handler, ctx context.Context, stop context.CancelFunc, done <-chan struct{}) (*Server, error) {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		stop()
		return nil, err
	}
	server := &http.Server{
		Handler: handler, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 12 * time.Second,
		WriteTimeout: 14 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8 << 10,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	go func() {
		defer stop()
		if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
			log.Printf("Pot listener: %v", err)
		}
	}()
	return &Server{URL: "http://" + listener.Addr().String(), http: server, stop: stop, done: done}, nil
}

func (s *Server) Close() error {
	s.stop()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	err := s.http.Shutdown(ctx)
	if err != nil {
		_ = s.http.Close()
	}
	if s.done != nil {
		select {
		case <-s.done:
		case <-ctx.Done():
		}
	}
	return err
}

func Endpoint(value string) (*url.URL, error) {
	u, err := url.Parse(value)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" ||
		(u.Scheme != "https" && !(u.Scheme == "http" && loopback(u.Hostname()))) {
		return nil, errors.New("Pot endpoints require HTTPS or HTTP on loopback, without embedded credentials")
	}
	return u, nil
}

func loopback(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

type Config struct {
	Address       string
	DataDir       string
	ReadToken     string
	WriteToken    string
	RenderURL     string
	RenderToken   string
	BrowserOrigin string
}

func StartWorlds(config Config) (*Server, error) {
	store, err := newStore(config.DataDir)
	if err != nil {
		return nil, err
	}
	read, err := authorization(config.ReadToken)
	if err != nil {
		return nil, err
	}
	publish, err := authorization(config.WriteToken)
	if err != nil {
		return nil, err
	}
	render, err := NewAPI(config.RenderURL, config.RenderToken, "")
	if err != nil {
		return nil, err
	}
	rooms := &sessions{rooms: make(map[string]*room)}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		packed(w, http.StatusOK, status{"pot-worlds", "ok"})
	})
	canRead := func(w http.ResponseWriter, r *http.Request) bool {
		token := r.Header.Get("Authorization")
		if !read.set || read.accepts(token) || publish.accepts(token) {
			return true
		}
		authRequired(w)
		return false
	}
	find := func(w http.ResponseWriter, id string) *world {
		item, err := store.load(id)
		if errors.Is(err, errWorldMissing) {
			fail(w, http.StatusNotFound, err.Error())
		} else if err != nil {
			fail(w, http.StatusInternalServerError, "the stored world could not be read")
		}
		return item
	}

	mux.HandleFunc("GET /v2/worlds", func(w http.ResponseWriter, r *http.Request) {
		if !canRead(w, r) {
			return
		}
		items, err := store.list()
		if err != nil {
			fail(w, http.StatusInternalServerError, "could not read the world library")
			return
		}
		packed(w, http.StatusOK, items)
	})
	mux.HandleFunc("GET /v2/worlds/{id}", func(w http.ResponseWriter, r *http.Request) {
		if canRead(w, r) {
			if item := find(w, r.PathValue("id")); item != nil {
				write(w, http.StatusOK, place.MIME, item.packed)
			}
		}
	})
	mux.HandleFunc("PUT /v2/worlds/{id}", func(w http.ResponseWriter, r *http.Request) {
		if !publish.set {
			fail(w, http.StatusForbidden, "publishing is disabled")
			return
		}
		if !publish.accepts(r.Header.Get("Authorization")) {
			authRequired(w)
			return
		}
		body, ok := readProject(w, r)
		if !ok {
			return
		}
		p, err := place.FromWire(body)
		if err != nil || p.ID != r.PathValue("id") {
			fail(w, http.StatusBadRequest, "invalid project or mismatched world ID")
			return
		}
		if err = store.save(p); errors.Is(err, errStoreFull) {
			fail(w, http.StatusConflict, err.Error())
			return
		} else if err != nil {
			fail(w, http.StatusInternalServerError, "could not store the world")
			return
		}
		rooms.changed(p.ID)
		packed(w, http.StatusOK, p.Summary())
	})
	mux.HandleFunc("GET /v2/worlds/{id}/thumbnail", func(w http.ResponseWriter, r *http.Request) {
		if !canRead(w, r) {
			return
		}
		item := find(w, r.PathValue("id"))
		if item == nil {
			return
		}
		png, err := render.Render(r.Context(), item.packed)
		if err != nil {
			fail(w, http.StatusBadGateway, "the thumbnail could not be rendered")
			return
		}
		write(w, http.StatusOK, "image/png", png)
	})
	mux.HandleFunc("GET /v2/session", func(w http.ResponseWriter, r *http.Request) {
		if canRead(w, r) {
			if item := find(w, r.URL.Query().Get("world")); item != nil {
				rooms.join(w, r, item, config.BrowserOrigin)
			}
		}
	})
	ctx, stop := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		rooms.run(ctx)
	}()
	return start(config.Address, mux, ctx, stop, done)
}

func StartRender(address, token string) (*Server, error) {
	find := make(map[[32]byte][]byte)
	var order [][32]byte
	var mu sync.Mutex
	workers := make(chan struct{}, 2)
	auth, err := authorization(token)
	if err != nil {
		return nil, err
	}
	host, _, err := net.SplitHostPort(address)
	if err != nil || (!loopback(host) && !auth.set) {
		return nil, errors.New("PRS requires a token on a non-loopback listener")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		packed(w, http.StatusOK, status{"PotRenderService", "ok"})
	})
	mux.HandleFunc("POST /v2/render", func(w http.ResponseWriter, r *http.Request) {
		if auth.set && !auth.accepts(r.Header.Get("Authorization")) {
			authRequired(w)
			return
		}
		data, ok := readProject(w, r)
		if !ok {
			return
		}
		key := sha256.Sum256(data)
		mu.Lock()
		saved := find[key]
		if saved != nil {
			order = append(slices.DeleteFunc(order, func(k [32]byte) bool { return k == key }), key)
		}
		mu.Unlock()
		if saved != nil {
			write(w, http.StatusOK, "image/png", saved)
			return
		}
		select {
		case workers <- struct{}{}:
			defer func() { <-workers }()
		default:
			w.Header().Set("Retry-After", "1")
			fail(w, http.StatusServiceUnavailable, "thumbnail workers are busy")
			return
		}
		p, err := place.FromWire(data)
		if err != nil {
			fail(w, http.StatusBadRequest, "invalid Pot project")
			return
		}
		ctx, stop := context.WithTimeout(r.Context(), 5*time.Second)
		defer stop()
		image, err := thumb.Render(ctx, p)
		if err != nil {
			fail(w, http.StatusGatewayTimeout, "thumbnail render timed out")
			return
		}
		mu.Lock()
		if find[key] == nil {
			find[key] = image
			order = append(order, key)
			if len(order) > 32 {
				delete(find, order[0])
				order = order[1:]
			}
		}
		mu.Unlock()
		write(w, http.StatusOK, "image/png", image)
	})
	ctx, stop := context.WithCancel(context.Background())
	return start(address, mux, ctx, stop, nil)
}
