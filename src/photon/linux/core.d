module photon.linux.core;
private:

import std.stdio;
import std.string;
import std.format;
import std.exception;
import std.conv;
import std.array;
import core.thread;
import core.internal.spinlock;
import core.sys.posix.sys.types;
import core.sys.posix.sys.socket;
import core.sys.posix.poll;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd;
import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sync.mutex;
import core.stdc.errno;
import core.atomic;
import core.sys.posix.stdlib: abort;
import core.sys.posix.fcntl;
import core.memory;
import core.sys.posix.sys.mman;
import core.sys.posix.pthread;
import core.sys.linux.sys.signalfd;

import photon.linux.support;
import photon.linux.syscalls;
import photon.ds.common;
import photon.ds.intrusive_queue;

// T becomes thread-local b/c it's stolen from shared resource
auto steal(T)(ref shared T arg)
{
    auto v = atomicLoad(arg);
    if (v !is null && cas(&arg, v, cast(shared(T))null)) {
        return v;
    }
    return null;
}


shared struct RawEvent {
nothrow:
    this(int init) {
        fd = eventfd(init, 0);
    }

    void waitAndReset() {
        ubyte[8] bytes = void;
        ssize_t r;
        do {
            r = raw_read(fd, bytes.ptr, 8);
        } while(r < 0 && errno == EINTR);
        r.checked("event reset");
    }
    
    void trigger() { 
        union U {
            ulong cnt;
            ubyte[8] bytes;
        }
        U value;
        value.cnt = 1;
        ssize_t r;
        do {
            r = raw_write(fd, value.bytes.ptr, 8);
        } while(r < 0 && errno == EINTR);
        r.checked("event trigger");
    }
    
    int fd;
}

struct Timer {
nothrow:
    private int timerfd;


    int fd() {
        return timerfd;
    }

    static void ms2ts(timespec *ts, ulong ms)
    {
        ts.tv_sec = ms / 1000;
        ts.tv_nsec = (ms % 1000) * 1000000;
    }

    void arm(int timeout) {
        timespec ts_timeout;
        ms2ts(&ts_timeout, timeout); //convert miliseconds to timespec
        itimerspec its;
        its.it_value = ts_timeout;
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 0;
        timerfd_settime(timerfd, 0, &its, null);
    }

    void disam() {
        itimerspec its; // zeros
        timerfd_settime(timerfd, 0, &its, null);
    }

    void dispose() { 
        close(timerfd).checked;
    }
}

Timer timer() {
    int timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC).checked;
    interceptFd!(Fcntl.noop)(timerfd);
    return Timer(timerfd);
}

enum EventState { ready, fibers };

shared struct Event {
    SpinLock lock = SpinLock(SpinLock.Contention.brief);
    EventState state = EventState.ready;
    FiberExt awaiting;

    void reset() {
        lock.lock();
        auto f = awaiting.unshared;
        awaiting = null;
        state = EventState.ready;
        lock.unlock();
        while(f !is null) {
            auto next = f.next;
            f.schedule();
            f = next;
        }
    }

    bool ready(){
        lock.lock();
        scope(exit) lock.unlock();
        return state == EventState.ready;
    }

    void await(){
        lock.lock();
        scope(exit) lock.unlock();
        if (state == EventState.ready) return;
        if (currentFiber !is null) {
            currentFiber.next = awaiting.unshared;
            awaiting = cast(shared)currentFiber;
            state = EventState.fibers;
        }
        else abort(); //TODO: threads
    }
}

struct AwaitingFiber {
    shared FiberExt fiber;
    AwaitingFiber* next;

    void scheduleAll(int wakeFd) nothrow
    {
        auto w = &this;
        FiberExt head;
        // first process all AwaitingFibers since they are on stack
        do {
            auto fiber = steal(w.fiber);
            if (fiber) {
                fiber.unshared.next = head;
                head = fiber.unshared;
            }
            w = w.next;
        } while(w);
        while(head) {
            logf("Waking with FD=%d", wakeFd);
            head.wakeFd = wakeFd;
            head.schedule();
            head = head.next;
        }
    }
}

class FiberExt : Fiber { 
    FiberExt next;
    uint numScheduler;
    int wakeFd; // recieves fd that woken us up

    enum PAGESIZE = 4096;
    
    this(void function() fn, uint numSched) nothrow {
        super(fn);
        numScheduler = numSched;
    }

    this(void delegate() dg, uint numSched) nothrow {
        super(dg);
        numScheduler = numSched;
    }

    void schedule() nothrow
    {
        scheds[numScheduler].queue.push(this);
    }
}

FiberExt currentFiber; 
shared RawEvent termination; // termination event, triggered once last fiber exits
shared pthread_t eventLoop; // event loop, runs outside of D runtime
shared int alive; // count of non-terminated Fibers scheduled

struct SchedulerBlock {
    shared IntrusiveQueue!(FiberExt, RawEvent) queue;
    shared uint assigned;
    size_t[2] padding;
}
static assert(SchedulerBlock.sizeof == 64);

package(photon) shared SchedulerBlock[] scheds;

enum int MAX_EVENTS = 500;
enum int SIGNAL = 42;

package(photon) void schedulerEntry(size_t n)
{
    int tid = gettid();
    cpu_set_t mask;
    CPU_SET(n, &mask);
    sched_setaffinity(tid, mask.sizeof, &mask).checked("sched_setaffinity");
    shared SchedulerBlock* sched = scheds.ptr + n;
    while (alive > 0) {
        sched.queue.event.waitAndReset();
        for(;;) {
            FiberExt f = sched.queue.drain();
            if (f is null) break; // drained an empty queue, time to sleep
            do {
                auto next = f.next; //save next, it will be reused on scheduling
                currentFiber = f;
                logf("Fiber %x started", cast(void*)f);
                try {
                    f.call();
                }
                catch (Exception e) {
                    stderr.writeln(e);
                    atomicOp!"-="(alive, 1);
                }
                if (f.state == FiberExt.State.TERM) {
                    logf("Fiber %s terminated", cast(void*)f);
                    atomicOp!"-="(alive, 1);
                }
                f = next;
            } while(f !is null);
        }
    }
    termination.trigger();
}

public void spawn(void delegate() func) {
    import std.random;
    uint a = uniform!"[)"(0, cast(uint)scheds.length);
    uint b = uniform!"[)"(0, cast(uint)scheds.length-1);
    if (a == b) b = cast(uint)scheds.length-1;
    uint loadA = scheds[a].assigned;
    uint loadB = scheds[b].assigned;
    uint choice;
    if (loadA < loadB) choice = a;
    else choice = b;
    atomicOp!"+="(scheds[choice].assigned, 1);
    atomicOp!"+="(alive, 1);
    auto f = new FiberExt(func, choice);
    f.schedule();
}

shared Descriptor[] descriptors;
shared int event_loop_fd;
shared int signal_loop_fd;

enum ReaderState: uint {
    EMPTY = 0,
    UNCERTAIN = 1,
    READING = 2,
    READY = 3
}

enum WriterState: uint {
    READY = 0,
    UNCERTAIN = 1,
    WRITING = 2,
    FULL = 3
}

enum DescriptorState: uint {
    NOT_INITED,
    INITIALIZING,
    NONBLOCKING,
    THREADPOOL
}

// list of awaiting fibers
shared struct Descriptor {
    ReaderState _readerState;   
    AwaitingFiber* _readerWaits;
    WriterState _writerState;
    AwaitingFiber* _writerWaits;
    DescriptorState state;
nothrow:
    ReaderState readerState()() {
        return atomicLoad(_readerState);
    }

    WriterState writerState()() {
        return atomicLoad(_writerState);
    }

    // try to change state & return whatever it happend to be in the end
    bool changeReader()(ReaderState from, ReaderState to) {
        return cas(&_readerState, from, to);
    }

    // ditto for writer
    bool changeWriter()(WriterState from, WriterState to) {
        return cas(&_writerState, from, to);
    }

    //
    shared(AwaitingFiber)* readWaiters()() {
        return atomicLoad(_readerWaits);
    }

    //
    shared(AwaitingFiber)* writeWaiters()(){
        return atomicLoad(_writerWaits);
    }

    // try to enqueue reader fiber given old head
    bool enqueueReader()(shared(AwaitingFiber)* fiber) {
        auto head = readWaiters;
        fiber.next = head;
        return cas(&_readerWaits, head, fiber);
    }

    // try to enqueue writer fiber given old head
    bool enqueueWriter()(shared(AwaitingFiber)* fiber) {
        auto head = writeWaiters;
        fiber.next = head;
        return cas(&_writerWaits, head, fiber);
    }

    // try to schedule readers - if fails - someone added a reader, it's now his job to check state
    void scheduleReaders()(int wakeFd) {
        auto w = steal(_readerWaits);
        if (w) w.unshared.scheduleAll(wakeFd);
    }

    // try to schedule writers, ditto
    void scheduleWriters()(int wakeFd) {
        auto w = steal(_writerWaits);
        if (w) w.unshared.scheduleAll(wakeFd);
    }
}

extern(C) void graceful_shutdown_on_signal(int, siginfo_t*, void*)
{
    version(photon_tracing) printStats();
    _exit(9);
}

version(photon_tracing) 
void printStats()
{
    // TODO: report on various events in eventloop/scheduler
    string msg = "Tracing report:\n\n";
    write(2, msg.ptr, msg.length);
}

public void startloop()
{
    import core.cpuid;
    uint threads = threadsPerCPU;

    event_loop_fd = cast(int)epoll_create1(0).checked("ERROR: Failed to create event-loop!");
    // use RT signals, disable default termination on signal received
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGNAL);
    pthread_sigmask(SIG_BLOCK, &mask, null).checked;
    signal_loop_fd = cast(int)signalfd(-1, &mask, 0).checked("ERROR: Failed to create signalfd!");

    epoll_event event;
    event.events = EPOLLIN;
    event.data.fd = signal_loop_fd;
    epoll_ctl(event_loop_fd, EPOLL_CTL_ADD, signal_loop_fd, &event).checked;

    termination = RawEvent(0);
    event.events = EPOLLIN;
    event.data.fd = termination.fd;
    epoll_ctl(event_loop_fd, EPOLL_CTL_ADD, termination.fd, &event).checked;

    {
        
        sigaction_t action;
        action.sa_sigaction = &graceful_shutdown_on_signal;
        sigaction(SIGTERM, &action, null).checked;
    }

    ssize_t fdMax = sysconf(_SC_OPEN_MAX).checked;
    descriptors = (cast(shared(Descriptor*)) mmap(null, fdMax * Descriptor.sizeof, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0))[0..fdMax];
    scheds = new SchedulerBlock[threads];
    foreach(ref sched; scheds) {
        sched.queue = IntrusiveQueue!(FiberExt, RawEvent)(RawEvent(0));
    }
    eventLoop = pthread_create(cast(pthread_t*)&eventLoop, null, &processEventsEntry, null);
}

package(photon) void stoploop()
{
    void* ret;
    pthread_join(eventLoop, &ret);
}

extern(C) void* processEventsEntry(void*)
{
    for (;;) {
        epoll_event[MAX_EVENTS] events = void;
        signalfd_siginfo[20] fdsi = void;
        int r;
        do {
            r = epoll_wait(event_loop_fd, events.ptr, MAX_EVENTS, -1);
        } while (r < 0 && errno == EINTR);
        checked(r);
        for (int n = 0; n < r; n++) {
            int fd = events[n].data.fd;
            if (fd == termination.fd) {
                foreach(ref s; scheds) s.queue.event.trigger();
                return null;
            }
            else if (fd == signal_loop_fd) {
                logf("Intercepted our aio SIGNAL");
                ssize_t r2 = raw_read(signal_loop_fd, &fdsi, fdsi.sizeof);
                logf("aio events = %d", r2 / signalfd_siginfo.sizeof);
                if (r2 % signalfd_siginfo.sizeof != 0)
                    checked(r2, "ERROR: failed read on signalfd");

                for(int i = 0; i < r2 / signalfd_siginfo.sizeof; i++) { //TODO: stress test multiple signals
                    logf("Processing aio event idx = %d", i);
                    if (fdsi[i].ssi_signo == SIGNAL) {
                        logf("HIT our SIGNAL");
                        auto fiber = cast(FiberExt)cast(void*)fdsi[i].ssi_ptr;
                        fiber.schedule();
                    }
                }
            }
            else {
                auto descriptor = descriptors.ptr + fd;
                if (descriptor.state == DescriptorState.NONBLOCKING) {
                    if (events[n].events & EPOLLIN) {
                        logf("Read event for fd=%d", fd);
                        auto state = descriptor.readerState;
                        logf("state = %d", state);
                        final switch(state) with(ReaderState) { 
                            case EMPTY:
                                descriptor.changeReader(EMPTY, READY);
                                descriptor.scheduleReaders(fd);
                                logf("Scheduled readers");
                                break;
                            case UNCERTAIN:
                                descriptor.changeReader(UNCERTAIN, READY);
                                break;
                            case READING:
                                if (!descriptor.changeReader(READING, UNCERTAIN)) {
                                    if (descriptor.changeReader(EMPTY, UNCERTAIN)) // if became empty - move to UNCERTAIN and wake readers
                                        descriptor.scheduleReaders(fd);
                                }
                                break;
                            case READY:
                                descriptor.scheduleReaders(fd);
                                break;
                        }
                        logf("Awaits %x", cast(void*)descriptor.readWaiters);
                    }
                    if (events[n].events & EPOLLOUT) {
                        logf("Write event for fd=%d", fd);
                        auto state = descriptor.writerState;
                        logf("state = %d", state);
                        final switch(state) with(WriterState) { 
                            case FULL:
                                descriptor.changeWriter(FULL, READY);
                                descriptor.scheduleWriters(fd);
                                break;
                            case UNCERTAIN:
                                descriptor.changeWriter(UNCERTAIN, READY);
                                break;
                            case WRITING:
                                if (!descriptor.changeWriter(WRITING, UNCERTAIN)) {
                                    if (descriptor.changeWriter(FULL, UNCERTAIN)) // if became empty - move to UNCERTAIN and wake writers
                                        descriptor.scheduleWriters(fd);
                                }
                                break;
                            case READY:
                                descriptor.scheduleWriters(fd);
                                break;
                        }
                        logf("Awaits %x", cast(void*)descriptor.writeWaiters);
                    }
                }
            }
        }
    }
}

enum Fcntl: int { explicit = 0, msg = MSG_DONTWAIT, sock = SOCK_NONBLOCK, noop = 0xFFFFF }
enum SyscallKind { accept, read, write }

// intercept - a filter for file descriptor, changes flags and register on first use
void interceptFd(Fcntl needsFcntl)(int fd) nothrow {
    logf("Hit interceptFD");
    if (fd < 0 || fd >= descriptors.length) return;
    if (cas(&descriptors[fd].state, DescriptorState.NOT_INITED, DescriptorState.INITIALIZING)) {
        logf("First use, registering fd = %d", fd);
        static if(needsFcntl == Fcntl.explicit) {
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK).checked;
        }
        epoll_event event;
        event.events = EPOLLIN | EPOLLOUT | EPOLLET;
        event.data.fd = fd;
        if (epoll_ctl(event_loop_fd, EPOLL_CTL_ADD, fd, &event) < 0 && errno == EPERM) {
            logf("isSocket = false FD = %d", fd);
            descriptors[fd].state = DescriptorState.THREADPOOL;
        }
        else {
            logf("isSocket = true FD = %d", fd);
            descriptors[fd].state = DescriptorState.NONBLOCKING;
        }
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (!(flags & O_NONBLOCK)) {
        logf("WARNING: Socket (%d) not set in O_NONBLOCK mode!", fd);
    }
}

void deregisterFd(int fd) nothrow {
    if(fd >= 0 && fd < descriptors.length) {
        auto descriptor = descriptors.ptr + fd;
        atomicStore(descriptor._writerState, WriterState.READY);
        atomicStore(descriptor._readerState, ReaderState.EMPTY);
        descriptor.scheduleReaders(fd);
        descriptor.scheduleWriters(fd);
        atomicStore(descriptor.state, DescriptorState.NOT_INITED);
    }
}

ssize_t universalSyscall(size_t ident, string name, SyscallKind kind, Fcntl fcntlStyle, ssize_t ERR, T...)
                        (int fd, T args) nothrow {
    if (currentFiber is null) {
        logf("%s PASSTHROUGH FD=%s", name, fd);
        return syscall(ident, fd, args).withErrorno;
    }
    else {
        logf("HOOKED %s FD=%d", name, fd);
        interceptFd!(fcntlStyle)(fd);
        shared(Descriptor)* descriptor = descriptors.ptr + fd;
        if (atomicLoad(descriptor.state) == DescriptorState.THREADPOOL) {
            logf("%s syscall THREADPOLL FD=%d", name, fd);
            //TODO: offload syscall to thread-pool
            return syscall(ident, fd, args).withErrorno;
        }
    L_start:
        shared AwaitingFiber await = AwaitingFiber(cast(shared)currentFiber, null);
        // set flags argument if able to avoid direct fcntl calls
        static if (fcntlStyle != Fcntl.explicit)
        {
            args[2] |= fcntlStyle;
        }
        static if(kind == SyscallKind.accept || kind == SyscallKind.read) {
            auto state = descriptor.readerState;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)currentFiber);
            final switch (state) with (ReaderState) {
            case EMPTY:
                logf("EMPTY - enqueue reader");
                if (!descriptor.enqueueReader(&await)) goto L_start;
                // changed state to e.g. READY or UNCERTAIN in meantime, may need to reschedule
                if (descriptor.readerState != EMPTY) descriptor.scheduleReaders(fd);
                FiberExt.yield();
                goto L_start;
            case UNCERTAIN:
                descriptor.changeReader(UNCERTAIN, READING); // may became READY or READING
                goto case READING;
            case READY:
                descriptor.changeReader(READY, READING); // always succeeds if 1 fiber reads
                goto case READING;
            case READING:
                ssize_t resp = syscall(ident, fd, args);
                static if (kind == SyscallKind.accept) {
                    if (resp >= 0) // for accept we never know if we emptied the queue
                        descriptor.changeReader(READING, UNCERTAIN);
                    else if (resp == -ERR || resp == -EAGAIN) {
                        if (descriptor.changeReader(READING, EMPTY))
                            goto case EMPTY;
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                }
                else static if (kind == SyscallKind.read) {
                    if (resp == args[1]) // length is 2nd in (buf, length, ...)
                        descriptor.changeReader(READING, UNCERTAIN);
                    else if(resp >= 0)
                        descriptor.changeReader(READING, EMPTY);
                    else if (resp == -ERR || resp == -EAGAIN) {
                        if (descriptor.changeReader(READING, EMPTY))
                            goto case EMPTY;
                        goto L_start; // became UNCERTAIN or READY in meantime
                    }
                }
                else
                    static assert(0);
                return withErrorno(resp);
            }
        }
        else static if(kind == SyscallKind.write) {
            //TODO: Handle short-write b/c of EWOULDBLOCK to apear as fully blocking
            auto state = descriptor.writerState;
            logf("%s syscall state is %d. Fiber %x", name, state, cast(void*)currentFiber);
            final switch (state) with (WriterState) {
            case FULL:
                if (!descriptor.enqueueWriter(&await)) goto L_start;
                // changed state to e.g. READY or UNCERTAIN in meantime, may need to reschedule
                if (descriptor.writerState != FULL) descriptor.scheduleWriters(fd);
                FiberExt.yield();
                goto L_start;
            case UNCERTAIN:
                descriptor.changeWriter(UNCERTAIN, WRITING); // may became READY or WRITING
                goto case WRITING;
            case READY:
                descriptor.changeWriter(READY, WRITING); // always succeeds if 1 fiber writes
                goto case WRITING;
            case WRITING:
                ssize_t resp = syscall(ident, fd, args);
                if (resp == args[1]) // (buf, len) args to syscall
                    descriptor.changeWriter(WRITING, UNCERTAIN);
                else if(resp >= 0)
                    descriptor.changeWriter(WRITING, FULL);
                else if (resp == -ERR || resp == -EAGAIN) {
                    if (descriptor.changeWriter(WRITING, FULL))
                        goto case FULL;
                    goto L_start; // became UNCERTAIN or READY in meantime
                }
                return withErrorno(resp);
            }
        }
        assert(0);
    }
}

// ======================================================================================
// SYSCALL warappers intercepts
// ======================================================================================

extern(C) ssize_t read(int fd, void *buf, size_t count) nothrow
{
    return universalSyscall!(SYS_READ, "READ", SyscallKind.read, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) ssize_t write(int fd, const void *buf, size_t count)
{
    return universalSyscall!(SYS_WRITE, "WRITE", SyscallKind.write, Fcntl.explicit, EWOULDBLOCK)
        (fd, cast(size_t)buf, count);
}

extern(C) ssize_t accept(int sockfd, sockaddr *addr, socklen_t *addrlen)
{
    return universalSyscall!(SYS_ACCEPT, "accept", SyscallKind.accept, Fcntl.explicit, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);    
}

extern(C) ssize_t accept4(int sockfd, sockaddr *addr, socklen_t *addrlen, int flags)
{
    return universalSyscall!(SYS_ACCEPT4, "accept4", SyscallKind.accept, Fcntl.sock, EWOULDBLOCK)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen, flags);
}

extern(C) ssize_t connect(int sockfd, const sockaddr *addr, socklen_t *addrlen)
{
    return universalSyscall!(SYS_CONNECT, "connect", SyscallKind.write, Fcntl.explicit, EINPROGRESS)
        (sockfd, cast(size_t) addr, cast(size_t) addrlen);
}

extern(C) ssize_t sendto(int sockfd, const void *buf, size_t len, int flags,
                      const sockaddr *dest_addr, socklen_t addrlen)
{
    return universalSyscall!(SYS_SENDTO, "sendto", SyscallKind.read, Fcntl.msg, EWOULDBLOCK)
        (sockfd, cast(size_t) buf, len, flags, cast(size_t) dest_addr, cast(size_t) addrlen);
}

extern(C) size_t recv(int sockfd, void *buf, size_t len, int flags) nothrow {
    sockaddr_in src_addr;
    src_addr.sin_family = AF_INET;
    src_addr.sin_port = 0;
    src_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    ssize_t addrlen = sockaddr_in.sizeof;
    return recvfrom(sockfd, buf, len, flags, cast(sockaddr*)&src_addr, &addrlen);   
}

extern(C) private ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags,
                        sockaddr *src_addr, ssize_t* addrlen) nothrow
{
    return universalSyscall!(SYS_RECVFROM, "RECVFROM", SyscallKind.read, Fcntl.msg, EWOULDBLOCK)
        (sockfd, cast(size_t)buf, len, flags, cast(size_t)src_addr, cast(size_t)addrlen);
}

extern(C) private ssize_t poll(pollfd *fds, nfds_t nfds, int timeout)
{
    bool nonBlockingCheck(ref ssize_t result) {
        bool uncertain;
    L_cacheloop:
        foreach (ref fd; fds[0..nfds]) {
            interceptFd!(Fcntl.explicit)(fd.fd);
            fd.revents = 0;
            auto descriptor = descriptors.ptr + fd.fd;
            if (fd.events & POLLIN) {
                auto state = descriptor.readerState;
                logf("Found event %d for reader in select", state);
                switch(state) with(ReaderState) {
                case READY:
                    fd.revents |=  POLLIN;
                    break;
                case EMPTY:
                    break;
                default:
                    uncertain = true;
                    break L_cacheloop;
                }
            }
            if (fd.events & POLLOUT) {
                auto state = descriptor.writerState;
                logf("Found event %d for writer in select", state);
                switch(state) with(WriterState) {
                case READY:
                    fd.revents |= POLLOUT;
                    break;
                case FULL:
                    break;
                default:
                    uncertain = true;
                    break L_cacheloop;
                }
            }
        }
        // fallback to system poll call if descriptor state is uncertain
        if (uncertain) {
            logf("Fallback to system poll, descriptors have uncertain state");
            ssize_t p = raw_poll(fds, nfds, 0);
            if (p != 0) {
                result = p;
                logf("Raw poll returns %d", result);
                return true;
            }
        }
        else {
            ssize_t j = 0;
            foreach (i; 0..nfds) {
                if (fds[i].revents) {
                    fds[j++] = fds[i];
                }
            }
            logf("Using our own event cache: %d events", j);
            if (j > 0) {
                result = cast(ssize_t)j;
                return true;
            }
        }
        return false;
    }
    if (currentFiber is null) {
        logf("POLL PASSTHROUGH!");
        return raw_poll(fds, nfds, timeout);
    }
    else {
        logf("HOOKED POLL %d fds timeout %d", nfds, timeout);
        if (nfds < 0) return -EINVAL.withErrorno;
        if (nfds == 0) {
            if (timeout == 0) return 0;
            shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)currentFiber);
            Timer tm = timer();
            descriptors[tm.fd].enqueueReader(&aw);
            scope(exit) tm.dispose();
            tm.arm(timeout);
            logf("Timer fd=%d", tm.fd);
            Fiber.yield();
            logf("Woke up after select %x. WakeFd=%d", cast(void*)currentFiber, currentFiber.wakeFd);
            return 0;
        }
        foreach(ref fd; fds[0..nfds]) {
            if (fd.fd < 0 || fd.fd >= descriptors.length) return -EBADF.withErrorno;
            fd.revents = 0;
        }
        ssize_t result = 0;
        if (timeout <= 0) return raw_poll(fds, nfds, timeout);
        if (nonBlockingCheck(result)) return result;
        AwaitingFiber[] awaits = new AwaitingFiber[nfds]; //TODO: pool allocate
        foreach (i; 0..nfds) {
            awaits[i] = AwaitingFiber(cast(shared)currentFiber);
            if (fds[i].events & POLLIN) {
                descriptors[fds[i].fd].enqueueReader(cast(shared)awaits.ptr + i);
            }
            else if(fds[i].events & POLLOUT)
                descriptors[fds[i].fd].enqueueWriter(cast(shared)awaits.ptr + i);
        }
        Timer tm = timer();
        scope(exit) tm.dispose();
        tm.arm(timeout);
        shared AwaitingFiber aw = shared(AwaitingFiber)(cast(shared)currentFiber);
        descriptors[tm.fd].enqueueReader(&aw);
        Fiber.yield();
        tm.disam();
        atomicStore(descriptors[tm.fd]._readerWaits, cast(shared(AwaitingFiber)*)null);
        logf("Woke up after select %x. WakeFD=%d", cast(void*)currentFiber, currentFiber.wakeFd);
        if (currentFiber.wakeFd == tm.fd) return 0;
        else {
            nonBlockingCheck(result);
            return result;
        }
    }
}

extern(C) private ssize_t close(int fd) nothrow
{
    logf("HOOKED CLOSE FD=%d", fd);
    deregisterFd(fd);
    return cast(int)withErrorno(syscall(SYS_CLOSE, fd));
}
