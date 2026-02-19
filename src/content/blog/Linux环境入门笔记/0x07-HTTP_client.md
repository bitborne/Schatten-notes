---
title: '0x07-HTTP_client'
description: ''
pubDate: 2026-02-20
---

# 0x07-HTTP_client

| **类型/结构体** | **所在头文件** | **作用** | **常用成员** | **备注** |
| --- | --- | --- | --- | --- |
| **in****_****addr** | `<netinet/in.h>` | 32 位 IPv4 数值 | `s_addr` | 直接 `inet_ntoa()` |
| **in6****_****addr** | `<netinet/in.h>` | 128 位 IPv6 数值 | `s6_addr[16]` | 用 `inet_ntop()` |
| **sockaddr****_****in** | `<netinet/in.h>` | IPv4 完整地址+端口 | `sin_family`,<br/> `sin_port`,<br/> `sin_addr` | 传给<br/> `connect/bind` |
| **sockaddr****_****in6** | `<netinet/in.h>` | IPv6 完整地址+端口 | `sin6_family`,<br/>`sin6_port`, <br/>`sin6_addr` | 同上 |
| **sockaddr****_****un** | `<sys/un.h>` | Unix 域路径 | `sun_family`,<br/> `sun_path` | 本地进程 IPC |
| **addrinfo** | `<netdb.h>` | getaddrinfo 结果节点 | `ai_addr`, <br/>`ai_next`, <br/>`ai_family`, <br/>`ai_socktype` | 现代推荐 |
| **hostent** | `<netdb.h>` | gethostbyname 结果 | `h_name`,<br/> `h_addr_list` | 已过时 |
| **sockaddr** | `<sys/socket.h>` | 通用抽象基类 | **无数据，仅用于强制转换** | 所有地址结构的“父类” |
| **sockaddr****_****storage** | `<sys/socket.h>` | 足够大的通用容器 | 无成员，直接强转 | 避免缓冲区溢出 |


1. **<font style="color:#DF2A3F;background-color:rgba(255, 255, 255, 0);">“sockaddr 是基类，sockaddr_in 是子类，强制转换就完事。”</font>**
2. **<font style="color:#DF2A3F;background-color:rgba(255, 255, 255, 0);">“IPv4 用 sockaddr_in，IPv6 用 sockaddr_in6，通用用 addrinfo。”</font>**
3. **<font style="color:#DF2A3F;background-color:rgba(255, 255, 255, 0);">“getaddrinfo 一条龙：解析、填结构、连 socket，用完 freeaddrinfo。”</font>**

```c
struct addrinfo {
    int ai_flags;       // 额外标志位
    int ai_family;      // AF_INET / AF_INET6 / AF_UNSPEC
    int ai_socktype;    // SOCK_STREAM / SOCK_DGRAM / 0
    int ai_protocol;    // IPPROTO_TCP / IPPROTO_UDP / 0
    socklen_t ai_addrlen;
    struct sockaddr *ai_addr;   // 可直接 bind/connect
    char *ai_canonname; // 若 AI_CANONNAME 置位，则含官方名
    struct addrinfo *ai_next;   // 下一条结果
   };
```

# 创建socket + 连接步骤
## 传统连接步骤
```c
/*=== 创建一个 IPv4、面向字节流（TCP）的 socket ===*/
  int sockfd = socket(AF_INET, SOCK_STREAM, 0); /* AF: Address Families */
  if (sockfd < 0) return -1;
  // sockfd:if (sockfd < 0) return -1; socket 文件描述符
  // AF_INET:  IPv4      AF_INET6: IPv6       AF_UNIX / AF_LOCAL: 本地进程间通信
  // SOCK_STREAM: TCP    SOCK_DGRAM: UDP

  struct sockaddr_in sin = {0}; // 包含 网络协议族(IPv4, IPv6), 端口, 地址 
  sin.sin_family = AF_INET;   // 网络协议族 实际是 unsigned short int == unsigned short  (2 bytes)
  sin.sin_port = htons(80);
  sin.sin_addr.s_addr = inet_addr(ip);     // 上面要传参 ip (char*)--> (unsigned int)
  /* 
  两个函数作用相反:
    inet_addr: char*    --> uint32_t
    inet_ntoa: uint32_t --> char*   
  */

  // 连接服务器
  if (connect(sockfd, (struct sockaddr*)&sin, sizeof(struct sockaddr_in))) {
    fprintf(stderr, "connect failed!\n");
    close(sockfd);
    return -1;
  }

// 设置 sockfd 为非阻塞 
fcntl(sockfd, F_SETFL, O_NONBLOCK);
```

## 使用 addrinfo 一步到位
还能遍历结果集中所有 ip, 直至连接成功

```c
struct addrinfo hints = {0}, *res = NULL;
hints.ai_family = AF_INET; // AF_UNSPEC: 可同时支持 IPv4和IPv6
hints.ai_socktype = SOCK_STREAM;


// 直接使用 hostname 获取sockaddr格式的地址结果 , 不需要涉及 点分ip和二进制ip的转化
int ret = getaddrinfo(hostname, service, &hints, &res); // res 是一个包含所有结果的链表
if (ret) {
  fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(ret));
  return -2;
}

int sockfd = -1; // 要作为返回值 return 出去
struct addrinfo* p = res;

for (; res != NULL; res = res->ai_next) {

  /* 创建 socketfd */ //==>  直接使用 addrinfo 成员变量作为参数! 好用!
  sockfd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
  if (sockfd < 0) continue;

  /* 直到连上一个合适的, 才break, 没连上记得 close */
  if (connect(sockfd, p->ai_addr, p->ai_addrlen) == 0) break;
  else close(sockfd);
}

if (!p) {
  perror("connect failed!\n");
  return -3;
}

freeaddrinfo(res);

// 设置 sockfd 为非阻塞 
fcntl(sockfd, F_SETFL, O_NONBLOCK);
```

# 完整流程: 创建连接 ->发送请求包
```c
char* http_send_request(const char* hostname, const char* resource) {

  // char* ip = host_to_ip(hostname);
  // printf("ip = %s\n", ip);
  // if (!ip) return NULL;
  // int sockfd = http_create_socket(ip);
  // if (sockfd < 0) return NULL;
//==> 可以全部换成下面这一行
  int sockfd = http_connect(hostname, "8888");
  if (sockfd < 0) return NULL;

  /*  tcp 连接已创建   */

// 接下来 组织 http 请求报文
  char req[REQ_SIZE] = {0};
  int req_len = snprintf(req, REQ_SIZE,  // \r回车, \n换行 
  "GET %s %s\r\n"
  "HOST: %s\r\n"    
  "%s\r\n"
  "\r\n",
  resource, HTTP_VERSION, hostname, CONNECTION_TYPE);

  if (send(sockfd, req, strlen(req), 0) != req_len) {
    fprintf(stderr, "send failed!\n");
    close(sockfd);
    return NULL;
  }

  // 由于I/O非阻塞, recv()的话很快就过去了, 根本收不到数据
  //=> 使用 select: `监听` `检测` 网络 I/O 是否返回可接收的数据
// fd_set: FD集合, 也就是一堆 I/O, |>使用 select 需先定义 fd_set<|

  fd_set fdread; // fd_set中, fd作为下标, 元素一旦置1, 就说明该下标对应 fd 有数据可读

  
  // 设置 select 超时时间: 5s 后自动返回 0
  struct timeval tv;
  tv.tv_sec = 5;
  tv.tv_usec = 0;
  
  size_t total = 0;
  char* buffer = calloc(1, BUFFER_SIZE); // 用于分次搬运的小货车
  char* result = calloc(1, sizeof(int)); // 由于最终会作为send_request函数的返回值, 留到 main 函数内, 调用者必须自主 free 
  while (1) {
    // 先置空, 每次循环都必须重置 fdread
    FD_ZERO(&fdread);
    FD_SET(sockfd, &fdread);
    
    
    
    // 非阻塞情况下, recv 立即返回, 需要while(1)循环recv才能接收数据, 此时会导致忙等待
    // select 会自动监控多个fd (这里就1个), 没有fd的时候会挂起, 不占CPU (超过timeout时间, 自动返回), 一旦有fd就绪, 立刻返回就绪的fd个数
    // 5个参数: select(maxfd + 1, &rset`关注哪些IO可读`, &wset`关注哪些IO可写`, &eset`关注哪些IO出错`, NULL `timeout: select多久算超时`)
    // 返回值: 就绪 fd 的个数
    int selection = select(sockfd + 1, &fdread, NULL, NULL, &tv);
    // 因为我们就一个FD, 如果 被设置的FD不是sockfd, 那肯定有错
    if (!selection || !FD_ISSET(sockfd, &fdread)) { // 超时<---大概率 (或者 fd 不是sockfd)
      fprintf(stderr, "select timeout\n");
      break;
    } else {

      int len = recv(sockfd, buffer, BUFFER_SIZE, 0);
      if (len <= 0) {    // == 0: 代表 disconnect      < 0 (-1): 代表出错
        break;
      }
// len > 0: 有数据
      // 动态扩容, 每接收 len 长度就多realloc len的大小
      result = realloc(result, (strlen(result) + len + 1) * sizeof(char)); 
      // +1 是为了接收最后一个终止符
      
      memcpy(result + total, buffer, len);
      total += len;
      // strncat(result, buffer, len);    // 每次都要遍历一遍result, 性能很差
    }
  }
  free(buffer);
  close(sockfd);
  return result;
}

int main(int argc, char* argv[]) {
  if (argc != 3) {
    fprintf(stderr, "Usage: %s <host> <path>\n", argv[0]);
    return -1;
  }

  char* response = http_send_request(argv[1], argv[2]);
  printf("Response:\n%s\n", response);

  free(response);

  return 0;
}
```
