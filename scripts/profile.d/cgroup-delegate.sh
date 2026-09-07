# Rootless podman can only enforce --memory/--cpus/--pids-limit inside the
# delegated cgroup subtree created by the cgroup-delegate service, and it has to
# be told to put containers there:
#
#   podman run --cgroup-parent="$PODMAN_CGROUP_PARENT" --memory=200m ...
#
if [ -d "/sys/fs/cgroup/deleg/u$(id -u)/containers" ]; then
	PODMAN_CGROUP_PARENT="/deleg/u$(id -u)/containers"
	export PODMAN_CGROUP_PARENT

	# The container process must be moved from this shell's cgroup into the
	# delegated subtree, which needs root once per session. Stay quiet when no
	# passwordless rule exists - run `sudo cg-attach $$` by hand in that case.
	case $- in
		*i*) sudo -n /usr/local/sbin/cg-attach $$ >/dev/null 2>&1 || true ;;
	esac
fi
