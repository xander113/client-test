package hub

import (
	"crypto/sha256"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"pot.local/runtime/internal/place"
)

const maxWorlds = 128

var (
	errWorldMissing = errors.New("this world could not be found")
	errStoreFull    = errors.New("the world library is full")
)

type world struct {
	place    *place.Place
	packed   []byte
	revision [sha256.Size]byte
}

func compileWorld(p *place.Place) (*world, error) {
	data, err := p.Marshal()
	if err != nil {
		return nil, err
	}
	return &world{p, data, sha256.Sum256(data)}, nil
}

type entry struct {
	path string
	info fs.FileInfo
	data *world
}

type store struct {
	dir          string
	mu           sync.Mutex
	starter      map[string]*world
	starterOrder []string
	cache        map[string]entry
}

func newStore(dir string) (*store, error) {
	s := &store{dir: dir, starter: make(map[string]*world), cache: make(map[string]entry)}
	if dir != "" {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
	}
	base, err := place.Samples()
	if err != nil {
		return nil, err
	}
	for _, p := range base {
		item, err := compileWorld(p)
		if err != nil {
			return nil, err
		}
		s.starter[p.ID] = item
		s.starterOrder = append(s.starterOrder, p.ID)
	}
	return s, nil
}

func (s *store) load(id string) (*world, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadLocked(id)
}

func (s *store) loadLocked(id string) (*world, error) {
	if !place.ValidID(id) {
		return nil, errWorldMissing
	}
	if s.dir != "" {
		for _, extension := range []string{".pot", ".json"} {
			path := filepath.Join(s.dir, "world-"+id+extension)
			info, err := os.Lstat(path)
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			if err != nil {
				return nil, err
			}
			if !info.Mode().IsRegular() {
				return nil, errors.New("invalid world library entry")
			}
			if prior, ok := s.cache[id]; ok && path == prior.path && os.SameFile(info, prior.info) &&
				info.Size() == prior.info.Size() && info.ModTime() == prior.info.ModTime() {
				return prior.data, nil
			}
			p, err := place.Load(path)
			if err != nil || p.ID != id {
				return nil, errors.New("could not read the stored world")
			}
			item, err := compileWorld(p)
			if err != nil {
				return nil, err
			}
			if len(s.cache) >= maxWorlds {
				clear(s.cache)
			}
			s.cache[id] = entry{path, info, item}
			return item, nil
		}
		delete(s.cache, id)
	} else if found, ok := s.cache[id]; ok {
		return found.data, nil
	}
	if found := s.starter[id]; found != nil {
		return found, nil
	}
	return nil, errWorldMissing
}

func (s *store) idsLocked() ([]string, error) {
	ids := slices.Clone(s.starterOrder)
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		seen[id] = true
	}
	appendID := func(id string) {
		if !seen[id] && place.ValidID(id) {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	if s.dir == "" {
		var recent []string
		for id := range s.cache {
			recent = append(recent, id)
		}
		slices.Sort(recent)
		for _, id := range recent {
			appendID(id)
		}
		return ids, nil
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	for _, f := range entries {
		id, valid := strings.CutPrefix(f.Name(), "world-")
		ext := filepath.Ext(id)
		if valid && f.Type().IsRegular() && (ext == ".pot" || ext == ".json") {
			appendID(strings.TrimSuffix(id, ext))
		}
	}
	return ids, nil
}

func (s *store) list() ([]place.Summary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids, err := s.idsLocked()
	if err != nil {
		return nil, err
	}
	summaries := make([]place.Summary, 0, min(maxWorlds, len(ids)))
	for _, id := range ids {
		item, err := s.loadLocked(id)
		if err == nil {
			summaries = append(summaries, item.place.Summary())
			if len(summaries) == maxWorlds {
				break
			}
		}
	}
	return summaries, nil
}

func (s *store) save(p *place.Place) error {
	item, err := compileWorld(p)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ids, err := s.idsLocked()
	if err != nil {
		return err
	}
	if len(ids) >= maxWorlds && !slices.Contains(ids, p.ID) {
		return errStoreFull
	}
	if s.dir == "" {
		s.cache[p.ID] = entry{data: item}
		return nil
	}
	if err = place.Save(filepath.Join(s.dir, "world-"+p.ID+".pot"), p); err != nil {
		return err
	}
	delete(s.cache, p.ID)
	return nil
}
