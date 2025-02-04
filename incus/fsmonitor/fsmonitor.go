package fsmonitor

import (
	"github.com/cyphar/incus/incus/fsmonitor/drivers"
	"github.com/cyphar/incus/shared/logger"
)

type fsMonitor struct {
	driver drivers.Driver
	logger logger.Logger
}

// PrefixPath returns the prefix path.
func (fs *fsMonitor) PrefixPath() string {
	return fs.driver.PrefixPath()
}

// Watch creates a watch for a path which may or may not yet exist. If the provided path gets an
// inotify event, f() is called.
// Note: If f() returns false, the watch is removed.
func (fs *fsMonitor) Watch(path string, identifier string, f func(path string, event string) bool) error {
	fs.logger.Info("Watching path", logger.Ctx{"path": path})

	return fs.driver.Watch(path, identifier, f)
}

// Unwatch removes the given path from the watchlist.
func (fs *fsMonitor) Unwatch(path string, identifier string) error {
	fs.logger.Info("Unwatching path", logger.Ctx{"path": path})

	return fs.driver.Unwatch(path, identifier)
}
