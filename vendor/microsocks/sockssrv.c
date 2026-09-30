/*
   MicroSocks - multithreaded, small, efficient SOCKS5 server.

   Copyright (C) 2017 rofl0r.

   This is the successor of "rocksocks5", and it was written with
   different goals in mind:

   - prefer usage of standard libc functions over homegrown ones
   - no artificial limits
   - do not aim for minimal binary size, but for minimal source code size,
     and maximal readability, reusability, and extensibility.

   as a result of that, ipv4, dns, and ipv6 is supported out of the box
   and can use the same code, while rocksocks5 has several compile time
   defines to bring down the size of the resulting binary to extreme values
   like 10 KB static linked when only ipv4 support is enabled.

   still, if optimized for size, *this* program when static linked against musl
   libc is not even 50 KB. that's easily usable even on the cheapest routers.

*/

#define _GNU_SOURCE
#include <unistd.h>
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <signal.h>
#include <poll.h>
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <time.h>
#include "server.h"
#include "sblist.h"

/* timeout in microseconds on resource exhaustion to prevent excessive
   cpu usage. */
#ifndef FAILURE_TIMEOUT
#define FAILURE_TIMEOUT 64
#endif

/* CFWarp bounds both unauthenticated handshakes and total client resources. */
#ifndef CFWARP_HANDSHAKE_TIMEOUT_SECONDS
#define CFWARP_HANDSHAKE_TIMEOUT_SECONDS 10
#endif
#ifndef CFWARP_MAX_CLIENTS
#define CFWARP_MAX_CLIENTS 128
#endif
#if CFWARP_HANDSHAKE_TIMEOUT_SECONDS < 1 || CFWARP_HANDSHAKE_TIMEOUT_SECONDS > 3600
#error CFWARP_HANDSHAKE_TIMEOUT_SECONDS must be between 1 and 3600
#endif
#if CFWARP_MAX_CLIENTS < 1 || CFWARP_MAX_CLIENTS > 65535
#error CFWARP_MAX_CLIENTS must be between 1 and 65535
#endif

#ifndef MAX
#define MAX(x, y) ((x) > (y) ? (x) : (y))
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#endif

#ifdef PTHREAD_STACK_MIN
#define THREAD_STACK_SIZE MAX(16*1024, PTHREAD_STACK_MIN)
#else
#define THREAD_STACK_SIZE 64*1024
#endif

#if defined(__APPLE__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 64*1024
#elif defined(__GLIBC__) || defined(__FreeBSD__) || defined(__sun__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 32*1024
#endif

static int quiet;
static const char* auth_user;
static const char* auth_pass;
static sblist* auth_ips;
static pthread_rwlock_t auth_ips_lock = PTHREAD_RWLOCK_INITIALIZER;
static const struct server* server;
static union sockaddr_union bind_addr = {.v4.sin_family = AF_UNSPEC};

enum socksstate {
	SS_1_CONNECTED,
	SS_2_NEED_AUTH, /* skipped if NO_AUTH method supported */
	SS_3_AUTHED,
};

enum authmethod {
	AM_NO_AUTH = 0,
	AM_GSSAPI = 1,
	AM_USERNAME = 2,
	AM_INVALID = 0xFF
};

enum errorcode {
	EC_SUCCESS = 0,
	EC_GENERAL_FAILURE = 1,
	EC_NOT_ALLOWED = 2,
	EC_NET_UNREACHABLE = 3,
	EC_HOST_UNREACHABLE = 4,
	EC_CONN_REFUSED = 5,
	EC_TTL_EXPIRED = 6,
	EC_COMMAND_NOT_SUPPORTED = 7,
	EC_ADDRESSTYPE_NOT_SUPPORTED = 8,
};

struct thread {
	pthread_t pt;
	struct client client;
	enum socksstate state;
	int done;
};
static pthread_mutex_t done_lock = PTHREAD_MUTEX_INITIALIZER;

#ifndef CONFIG_LOG
#define CONFIG_LOG 1
#endif
#if CONFIG_LOG
/* we log to stderr because it's not using line buffering, i.e. malloc which would need
   locking when called from different threads. for the same reason we use dprintf,
   which writes directly to an fd. */
#define dolog(...) do { if(!quiet) dprintf(2, __VA_ARGS__); } while(0)
#else
static void dolog(const char* fmt, ...) { }
#endif

static struct addrinfo* addr_choose(struct addrinfo* list, union sockaddr_union* bindaddr) {
	int af = SOCKADDR_UNION_AF(bindaddr);
	if(af == AF_UNSPEC) return list;
	struct addrinfo* p;
	for(p=list; p; p=p->ai_next)
		if(p->ai_family == af) return p;
	return list;
}

static int connect_socks_target(unsigned char *buf, size_t n, struct client *client) {
	if(n < 5) return -EC_GENERAL_FAILURE;
	if(buf[0] != 5) return -EC_GENERAL_FAILURE;
	if(buf[1] != 1) return -EC_COMMAND_NOT_SUPPORTED; /* we support only CONNECT method */
	if(buf[2] != 0) return -EC_GENERAL_FAILURE; /* malformed packet */

	int af = AF_INET;
	size_t minlen = 4 + 4 + 2, l;
	char namebuf[256];
	struct addrinfo* remote;

	switch(buf[3]) {
		case 4: /* ipv6 */
			af = AF_INET6;
			minlen = 4 + 2 + 16;
			/* fall through */
		case 1: /* ipv4 */
			if(n < minlen) return -EC_GENERAL_FAILURE;
			if(namebuf != inet_ntop(af, buf+4, namebuf, sizeof namebuf))
				return -EC_GENERAL_FAILURE; /* malformed or too long addr */
			break;
		case 3: /* dns name */
			l = buf[4];
			minlen = 4 + 2 + l + 1;
			if(n < 4 + 2 + l + 1) return -EC_GENERAL_FAILURE;
			memcpy(namebuf, buf+4+1, l);
			namebuf[l] = 0;
			break;
		default:
			return -EC_ADDRESSTYPE_NOT_SUPPORTED;
	}
	unsigned short port;
	port = (buf[minlen-2] << 8) | buf[minlen-1];
	/* there's no suitable errorcode in rfc1928 for dns lookup failure */
	if(resolve(namebuf, port, &remote)) return -EC_GENERAL_FAILURE;
	struct addrinfo* raddr = addr_choose(remote, &bind_addr);
	int fd = socket(raddr->ai_family, SOCK_STREAM, 0);
	if(fd == -1) {
		eval_errno:
		if(fd != -1) close(fd);
		freeaddrinfo(remote);
		switch(errno) {
			case ETIMEDOUT:
				return -EC_TTL_EXPIRED;
			case EPROTOTYPE:
			case EPROTONOSUPPORT:
			case EAFNOSUPPORT:
				return -EC_ADDRESSTYPE_NOT_SUPPORTED;
			case ECONNREFUSED:
				return -EC_CONN_REFUSED;
			case ENETDOWN:
			case ENETUNREACH:
				return -EC_NET_UNREACHABLE;
			case EHOSTUNREACH:
				return -EC_HOST_UNREACHABLE;
			case EBADF:
			default:
			perror("socket/connect");
			return -EC_GENERAL_FAILURE;
		}
	}
	if(SOCKADDR_UNION_AF(&bind_addr) == raddr->ai_family &&
	   bindtoip(fd, &bind_addr) == -1)
		goto eval_errno;
	if(connect(fd, raddr->ai_addr, raddr->ai_addrlen) == -1)
		goto eval_errno;

	freeaddrinfo(remote);
	if(CONFIG_LOG) {
		char clientname[256];
		af = SOCKADDR_UNION_AF(&client->addr);
		void *ipdata = SOCKADDR_UNION_ADDRESS(&client->addr);
		inet_ntop(af, ipdata, clientname, sizeof clientname);
		dolog("client[%d] %s: connected to %s:%d\n", client->fd, clientname, namebuf, port);
	}
	return fd;
}

static int is_authed(union sockaddr_union *client, union sockaddr_union *authedip) {
	int af = SOCKADDR_UNION_AF(authedip);
	if(af == SOCKADDR_UNION_AF(client)) {
		size_t cmpbytes = af == AF_INET ? 4 : 16;
		void *cmp1 = SOCKADDR_UNION_ADDRESS(client);
		void *cmp2 = SOCKADDR_UNION_ADDRESS(authedip);
		if(!memcmp(cmp1, cmp2, cmpbytes)) return 1;
	}
	return 0;
}

static int is_in_authed_list(union sockaddr_union *caddr) {
	size_t i;
	for(i=0;i<sblist_getsize(auth_ips);i++)
		if(is_authed(caddr, sblist_get(auth_ips, i)))
			return 1;
	return 0;
}

static void add_auth_ip(union sockaddr_union *caddr) {
	sblist_add(auth_ips, caddr);
}

static enum authmethod check_auth_method(unsigned char *buf, size_t n, struct client*client) {
	if(buf[0] != 5) return AM_INVALID;
	size_t idx = 1;
	if(idx >= n ) return AM_INVALID;
	int n_methods = buf[idx];
	idx++;
	while(idx < n && n_methods > 0) {
		if(buf[idx] == AM_NO_AUTH) {
			if(!auth_user) return AM_NO_AUTH;
			else if(auth_ips) {
				int authed = 0;
				if(pthread_rwlock_rdlock(&auth_ips_lock) == 0) {
					authed = is_in_authed_list(&client->addr);
					pthread_rwlock_unlock(&auth_ips_lock);
				}
				if(authed) return AM_NO_AUTH;
			}
		} else if(buf[idx] == AM_USERNAME) {
			if(auth_user) return AM_USERNAME;
		}
		idx++;
		n_methods--;
	}
	return AM_INVALID;
}

static void send_auth_response(int fd, int version, enum authmethod meth) {
	unsigned char buf[2];
	buf[0] = version;
	buf[1] = meth;
	write(fd, buf, 2);
}

static void send_error(int fd, enum errorcode ec) {
	/* position 4 contains ATYP, the address type, which is the same as used in the connect
	   request. we're lazy and return always IPV4 address type in errors. */
	char buf[10] = { 5, ec, 0, 1 /*AT_IPV4*/, 0,0,0,0, 0,0 };
	write(fd, buf, 10);
}

static void copyloop(int fd1, int fd2) {
	struct pollfd fds[2] = {
		[0] = {.fd = fd1, .events = POLLIN},
		[1] = {.fd = fd2, .events = POLLIN},
	};

	while(1) {
		/* inactive connections are reaped after 15 min to free resources.
		   usually programs send keep-alive packets so this should only happen
		   when a connection is really unused. */
		switch(poll(fds, 2, 60*15*1000)) {
			case 0:
				return;
			case -1:
				if(errno == EINTR || errno == EAGAIN) continue;
				else perror("poll");
				return;
		}
		int infd = (fds[0].revents & POLLIN) ? fd1 : fd2;
		int outfd = infd == fd2 ? fd1 : fd2;
		/* since the biggest stack consumer in the entire code is
		   libc's getaddrinfo(), we can safely use at least half the
		   available stacksize to improve throughput. */
		char buf[MIN(16*1024, THREAD_STACK_SIZE/2)];
		ssize_t sent = 0, n = read(infd, buf, sizeof buf);
		if(n <= 0) return;
		while(sent < n) {
			ssize_t m = write(outfd, buf+sent, n-sent);
			if(m < 0) return;
			sent += m;
		}
	}
}

static enum errorcode check_credentials(unsigned char* buf, size_t n) {
	if(n < 5) return EC_GENERAL_FAILURE;
	if(buf[0] != 1) return EC_GENERAL_FAILURE;
	unsigned ulen, plen;
	ulen=buf[1];
	if(n < 2 + ulen + 2) return EC_GENERAL_FAILURE;
	plen=buf[2+ulen];
	if(n < 2 + ulen + 1 + plen) return EC_GENERAL_FAILURE;
	char user[256], pass[256];
	memcpy(user, buf+2, ulen);
	memcpy(pass, buf+2+ulen+1, plen);
	user[ulen] = 0;
	pass[plen] = 0;
	if(!strcmp(user, auth_user) && !strcmp(pass, auth_pass)) return EC_SUCCESS;
	return EC_NOT_ALLOWED;
}

/* TCP preserves bytes, not message boundaries. Consume exactly one frame at a
   time, leaving any pipelined application data in the socket. One monotonic
   deadline covers the entire handshake; sending occasional bytes cannot renew
   it. The global client cap also bounds blocked DNS/connect/copy workers. */
static int recv_exact(int fd, unsigned char *buf, size_t length, const struct timespec *deadline) {
	size_t offset = 0;
	while(offset < length) {
		struct timespec now;
		if(clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
		long long remaining = (long long)(deadline->tv_sec - now.tv_sec) * 1000000000LL
			+ deadline->tv_nsec - now.tv_nsec;
		if(remaining <= 0) return -1;
		struct pollfd pfd = {.fd = fd, .events = POLLIN};
		int ready = poll(&pfd, 1, (int)((remaining + 999999) / 1000000));
		if(ready < 0 && errno == EINTR) continue;
		if(ready <= 0 || (pfd.revents & POLLNVAL)) return -1;
		ssize_t n = recv(fd, buf + offset, length - offset, MSG_DONTWAIT);
		if(n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
		if(n <= 0) return -1;
		offset += (size_t)n;
	}
	return 0;
}

static int handshake(struct thread *t) {
	unsigned char buf[1024];
	size_t n;
	int ret;
	enum authmethod am;
	struct timespec deadline;
	if(clock_gettime(CLOCK_MONOTONIC, &deadline)) return -1;
	deadline.tv_sec += CFWARP_HANDSHAKE_TIMEOUT_SECONDS;
	t->state = SS_1_CONNECTED;
	while(1) {
		switch(t->state) {
			case SS_1_CONNECTED:
				if(recv_exact(t->client.fd, buf, 2, &deadline)) return -1;
				n = 2 + buf[1];
				if(recv_exact(t->client.fd, buf + 2, n - 2, &deadline)) return -1;
				am = check_auth_method(buf, n, &t->client);
				if(am == AM_NO_AUTH) t->state = SS_3_AUTHED;
				else if (am == AM_USERNAME) t->state = SS_2_NEED_AUTH;
				send_auth_response(t->client.fd, 5, am);
				if(am == AM_INVALID) return -1;
				break;
			case SS_2_NEED_AUTH:
				if(recv_exact(t->client.fd, buf, 2, &deadline)) return -1;
				n = 2 + buf[1];
				if(recv_exact(t->client.fd, buf + 2, n - 2 + 1, &deadline)) return -1;
				n += 1 + buf[n];
				if(recv_exact(t->client.fd, buf + 3 + buf[1], n - 3 - buf[1], &deadline)) return -1;
				ret = check_credentials(buf, n);
				send_auth_response(t->client.fd, 1, ret);
				if(ret != EC_SUCCESS)
					return -1;
				t->state = SS_3_AUTHED;
				if(auth_ips && !pthread_rwlock_wrlock(&auth_ips_lock)) {
					if(!is_in_authed_list(&t->client.addr))
						add_auth_ip(&t->client.addr);
					pthread_rwlock_unlock(&auth_ips_lock);
				}
				break;
			case SS_3_AUTHED:
				if(recv_exact(t->client.fd, buf, 4, &deadline)) return -1;
				switch(buf[3]) {
					case 1: n = 10; break;
					case 4: n = 22; break;
					case 3:
						if(recv_exact(t->client.fd, buf + 4, 1, &deadline)) return -1;
						n = 7 + buf[4];
						if(recv_exact(t->client.fd, buf + 5, n - 5, &deadline)) return -1;
						break;
					default: send_error(t->client.fd, EC_ADDRESSTYPE_NOT_SUPPORTED); return -1;
				}
				if(buf[3] != 3 && recv_exact(t->client.fd, buf + 4, n - 4, &deadline)) return -1;
				ret = connect_socks_target(buf, n, &t->client);
				if(ret < 0) {
					send_error(t->client.fd, ret*-1);
					return -1;
				}
				send_error(t->client.fd, EC_SUCCESS);
				return ret;
		}
	}
	return -1;
}

static void* clientthread(void *data) {
	struct thread *t = data;
	int remotefd = handshake(t);
	if(remotefd != -1) {
		copyloop(t->client.fd, remotefd);
		close(remotefd);
	}
	close(t->client.fd);
	pthread_mutex_lock(&done_lock);
	t->done = 1;
	pthread_mutex_unlock(&done_lock);
	return 0;
}

static void collect(sblist *threads) {
	size_t i;
	for(i=0;i<sblist_getsize(threads);) {
		struct thread* thread = *((struct thread**)sblist_get(threads, i));
		pthread_mutex_lock(&done_lock);
		int done = thread->done;
		pthread_mutex_unlock(&done_lock);
		if(done) {
			pthread_join(thread->pt, 0);
			sblist_delete(threads, i);
			free(thread);
		} else
			i++;
	}
}

static int usage(void) {
	dprintf(2,
		"MicroSocks SOCKS5 Server\n"
		"------------------------\n"
		"usage: microsocks -1 -q -i listenip -p port -u user -P pass -b bindaddr -w ips\n"
		"all arguments are optional.\n"
		"by default listenip is 0.0.0.0 and port 1080.\n\n"
		"option -q disables logging.\n"
		"option -b specifies which ip outgoing connections are bound to\n"
		"option -w allows to specify a comma-separated whitelist of ip addresses,\n"
		" that may use the proxy without user/pass authentication.\n"
		" e.g. -w 127.0.0.1,192.168.1.1.1,::1 or just -w 10.0.0.1\n"
		" to allow access ONLY to those ips, choose an impossible to guess user/pw combo.\n"
		"option -1 activates auth_once mode: once a specific ip address\n"
		" authed successfully with user/pass, it is added to a whitelist\n"
		" and may use the proxy without auth.\n"
		" this is handy for programs like firefox that don't support\n"
		" user/pass auth. for it to work you'd basically make one connection\n"
		" with another program that supports it, and then you can use firefox too.\n"
	);
	return 1;
}

/* prevent username and password from showing up in top. */
static void zero_arg(char *s) {
	size_t i, l = strlen(s);
	for(i=0;i<l;i++) s[i] = 0;
}

int main(int argc, char** argv) {
	int ch;
	const char *listenip = "0.0.0.0";
	char *p, *q;
	unsigned port = 1080;
	while((ch = getopt(argc, argv, ":1qb:i:p:u:P:w:")) != -1) {
		switch(ch) {
			case 'w': /* fall-through */
			case '1':
				if(!auth_ips)
					auth_ips = sblist_new(sizeof(union sockaddr_union), 8);
				if(ch == '1') break;
				p = optarg;
				while(1) {
					union sockaddr_union ca;
					if((q = strchr(p, ','))) *q = 0;
					if(resolve_sa(p, 0, &ca)) {
						dprintf(2, "error: failed to resolve %s\n", p);
						return 1;
					}
					add_auth_ip(&ca);
					if(q) *(q++) = ',', p = q;
					else break;
				}
				break;
			case 'q':
				quiet = 1;
				break;
			case 'b':
				resolve_sa(optarg, 0, &bind_addr);
				break;
			case 'u':
				auth_user = strdup(optarg);
				zero_arg(optarg);
				break;
			case 'P':
				auth_pass = strdup(optarg);
				zero_arg(optarg);
				break;
			case 'i':
				listenip = optarg;
				break;
			case 'p':
				port = atoi(optarg);
				break;
			case ':':
				dprintf(2, "error: option -%c requires an operand\n", optopt);
				/* fall through */
			case '?':
				return usage();
		}
	}
	if((auth_user && !auth_pass) || (!auth_user && auth_pass)) {
		dprintf(2, "error: user and pass must be used together\n");
		return 1;
	}
	if(auth_ips && !auth_pass) {
		dprintf(2, "error: -1/-w options must be used together with user/pass\n");
		return 1;
	}
	signal(SIGPIPE, SIG_IGN);
	struct server s;
	sblist *threads = sblist_new(sizeof (struct thread*), 8);
	if(!threads) return 1;
	if(server_setup(&s, listenip, port)) {
		perror("server_setup");
		return 1;
	}
	server = &s;

	while(1) {
		collect(threads);
		struct client c;
		if(server_waitclient(&s, &c)) {
			dolog("failed to accept connection\n");
			usleep(FAILURE_TIMEOUT);
			continue;
		}
		/* Reap clients that finished while accept() was waiting. */
		collect(threads);
		if(sblist_getsize(threads) >= CFWARP_MAX_CLIENTS) {
			close(c.fd);
			continue;
		}
		struct thread *curr = malloc(sizeof (struct thread));
		if(!curr) { close(c.fd); goto oom; }
		curr->done = 0;
		curr->client = c;
		if(!sblist_add(threads, &curr)) {
			close(curr->client.fd);
			free(curr);
			oom:
			dolog("rejecting connection due to OOM\n");
			usleep(FAILURE_TIMEOUT); /* prevent 100% CPU usage in OOM situation */
			continue;
		}
		pthread_attr_t *a = 0, attr;
		if(pthread_attr_init(&attr) == 0) {
			a = &attr;
			pthread_attr_setstacksize(a, THREAD_STACK_SIZE);
		}
		if(pthread_create(&curr->pt, a, clientthread, curr) != 0) {
			dolog("pthread_create failed. OOM?\n");
			sblist_delete(threads, sblist_getsize(threads) - 1);
			close(curr->client.fd);
			free(curr);
		}
		if(a) pthread_attr_destroy(&attr);
	}
}
