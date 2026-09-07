#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void)
{
#ifndef SO_NOSIGPIPE
    fprintf(stderr, "SO_NOSIGPIPE is unavailable on this Apple target\n");
    return 1;
#else
    int sockets[2] = { -1, -1 };
    if(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0)
        return 2;

    int enabled = 1;
    if(setsockopt(
        sockets[0],
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        (socklen_t)sizeof(enabled)) != 0)
        return 3;

    if(close(sockets[1]) != 0)
        return 4;
    sockets[1] = -1;

    errno = 0;
    const char byte = 'x';
    const ssize_t sent = send(sockets[0], &byte, sizeof(byte), 0);
    const int send_errno = errno;
    close(sockets[0]);

    if(sent != -1 || send_errno != EPIPE)
        return 5;

    printf("REGISTRATION SOCKET VERIFIED  closed-peer send returns EPIPE without SIGPIPE\n");
    return 0;
#endif
}
