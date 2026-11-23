package hub

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"time"

	"github.com/gorilla/websocket"
	"pot.local/runtime/internal/place"
)

type API struct {
	base       *url.URL
	http       *http.Client
	readToken  string
	writeToken string
}

func NewAPI(value, readToken, writeToken string) (*API, error) {
	base, err := Endpoint(value)
	if err != nil {
		return nil, err
	}
	return &API{base, &http.Client{
		Timeout: 8 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}, readToken, writeToken}, nil
}

func (a *API) request(ctx context.Context, method, route, token, media string, data []byte, limit int64) ([]byte, error) {
	u := a.base.JoinPath(route)
	req, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if data != nil {
		req.Header.Set("Content-Type", place.MIME)
	}
	res, err := a.http.Do(req)
	if err != nil {
		return nil, errors.New("could not reach the Pot service")
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		switch res.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return nil, errors.New("the Pot service denied access")
		case http.StatusNotFound:
			return nil, errWorldMissing
		default:
			return nil, fmt.Errorf("the Pot service returned status %d", res.StatusCode)
		}
	}
	content, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	if content != media {
		return nil, errors.New("the Pot service sent an unsupported response")
	}
	result, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil || int64(len(result)) > limit {
		return nil, errors.New("the Pot service sent an incomplete or oversized response")
	}
	return result, nil
}

func (a *API) Health(ctx context.Context) error {
	_, err := a.request(ctx, http.MethodGet, "healthz", a.readToken, place.MIME, nil, 512)
	return err
}

func (a *API) List(ctx context.Context) ([]place.Summary, error) {
	data, err := a.request(ctx, http.MethodGet, "v2/worlds", a.readToken, place.MIME, nil, place.MaxSize)
	if err != nil {
		return nil, err
	}
	var summaries []place.Summary
	err = place.Unpack(data, &summaries)
	if len(summaries) > maxWorlds {
		return nil, errors.New("the Pot library is too large")
	}
	for _, world := range summaries {
		if !place.ValidID(world.ID) || len(world.Name) > 320 || len(world.Description) > 1600 {
			return nil, errors.New("the Pot library has an invalid entry")
		}
	}
	return summaries, err
}

func (a *API) Load(ctx context.Context, id string) (*place.Place, error) {
	if !place.ValidID(id) {
		return nil, errWorldMissing
	}
	data, err := a.request(ctx, http.MethodGet, "v2/worlds/"+id, a.readToken, place.MIME, nil, place.MaxSize)
	if err != nil {
		return nil, err
	}
	content, err := place.FromWire(data)
	if err == nil && content.ID != id {
		return nil, errors.New("the Pot service sent a different world")
	}
	return content, err
}

func (a *API) Publish(ctx context.Context, scene *place.Place) (place.Summary, error) {
	if a.writeToken == "" {
		return place.Summary{}, errors.New("publishing requires a Studio credential")
	}
	data, err := scene.Marshal()
	if err != nil {
		return place.Summary{}, err
	}
	_, err = a.request(ctx, http.MethodPut, "v2/worlds/"+scene.ID, a.writeToken, place.MIME, data, 4096)
	return scene.Summary(), err
}

func (a *API) Preview(ctx context.Context, id string) ([]byte, error) {
	if !place.ValidID(id) {
		return nil, errWorldMissing
	}
	data, err := a.request(ctx, http.MethodGet, "v2/worlds/"+id+"/thumbnail", a.readToken, "image/png", nil, maxPNGBytes)
	return checkPNG(data, err)
}

func (a *API) Render(ctx context.Context, data []byte) ([]byte, error) {
	image, err := a.request(ctx, http.MethodPost, "v2/render", a.readToken, "image/png", data, maxPNGBytes)
	return checkPNG(image, err)
}

func checkPNG(data []byte, err error) ([]byte, error) {
	if err != nil {
		return nil, err
	}
	if !bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")) {
		return nil, errors.New("the Pot service returned an invalid PNG")
	}
	return data, nil
}

func (a *API) Connect(ctx context.Context, id string) (*websocket.Conn, error) {
	if !place.ValidID(id) {
		return nil, errWorldMissing
	}
	u := a.base.JoinPath("v2/session")
	scheme := "ws"
	if u.Scheme == "https" {
		scheme = "wss"
	}
	u.Scheme, u.RawQuery = scheme, url.Values{"world": {id}}.Encode()
	headers := make(http.Header)
	if a.readToken != "" {
		headers.Set("Authorization", "Bearer "+a.readToken)
	}
	dialer := websocket.Dialer{
		Proxy: http.ProxyFromEnvironment, HandshakeTimeout: 6 * time.Second,
	}
	connection, res, err := dialer.DialContext(ctx, u.String(), headers)
	if err != nil {
		if res != nil {
			_ = res.Body.Close()
		}
		return nil, errors.New("could not join the Pot session")
	}
	connection.SetReadLimit(64 << 10)
	return connection, nil
}
