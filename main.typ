#import "@preview/touying:0.6.1": *
#import "@preview/touying-buaa:0.2.0": *

// Specify `lang` and `font` for the theme if needed.
#show: buaa-theme.with(
  // lang: "zh",
  font: (
    (
      name: "Comic Relief",
      covers: "latin-in-cjk",
    ),
    "Source Han Sans SC",
    "Source Han Sans",
  ),
  config-info(
    title: [Kubernetes Control Plane in Depth],
    // subtitle: [Customize Your Slide Subtitle Here],
    author: [Ziping Sun],
    date: datetime.today(),
    // institution: [Beihang University],
    logo: [],
  ),
)

#title-slide()
#let dimmed = text.with(fill: gray.darken(30%))

= Overview

== Overview: Components

#align(center)[
  #image("assets/components-of-kubernetes.svg", width: 90%)
]

Control Plane: API Server, Controller Manager, Scheduler, #dimmed[etcd]

// - 分为控制面数据面，数据面负责具体的容器操作
// - 控制面核心组件
// - Cloud Controller Manager: 与云服务相关
// - API Sever: 所有请求的 hub
// - Controller Manager: 业务逻辑，内部打包了很多 controller
// - Scheduler: 将 Pod 分配到 Node 上
// - 数据面读取控制面 desire 状态，执行具体的操作。
// - 这次 share 主要关心 API Server 和 Controller Manager

== Overview: Hub-and-Spoke Pattern

#align(center)[
  #image("assets/spoke-and-hub.png", width: 90%)
]

// - K8s 核心的一个重要的 pattern 是 hub-and-spoke: 所有组建通过 API Server 进行通信
// - 即使 controller manager 打包了 Deployment、ReplicaSet，它们彼此并不直接通信。当然它们可以共享缓存
// - API Server 本身只包含与鉴权、审计、admission
// - 这样的好处是：
//   - 耦合度低，便于扩展
//   - 请求集中进行认证、授权、审计等操作

= Component: API Server

// 接下来我们先关注 API Server 的实现

== API Server: Overview

#align(center)[
  #image("assets/kube-apiserver-overview.svg", width: 90%)
]

#text(size: 0.8em)[
  Request Flow: Middlewares (Authn, Audit, Flow Control, RBAC, Admission ...) #sym.arrow.r APIs #sym.arrow.r Storage
]

// 我将 API Server 分为 3 层：API、Middleware、Storage 三层。
// 其中 API 是面向用户、集群其他组件的 RESTful 接口
// Middleware 则提供了 Authentication、RBAC 等逻辑，像 RBAC、Admission 这类的中间件可以通过增删改对应的资源来配置
// Storage 负责持久化、并发控制。这里我们还会着重关注一下 Watch-LIst
// 一个请求会经历各种 middleware 的处理，Auth、RBAC、Admission 等等，而后到 API 层面进行处理，最后到达 Storage 层面进行查询、持久化

== API Server: APIs

#slide(composer: (2fr, 3fr))[
  #image("assets/kube-apiserver-apis.svg")

  API Categories
  #text(size: 0.8em)[
    - *Native* APIs
    - CRDs: *batch.volcano.sh*
    - Aggregated APIs: *metrics.k8s.io*
  ]
][
  What makes native resources special?
  #text(size: 0.8em)[
    - Special subresources\
      ~~pods *resize/ephemeralcontainers/eviction/binding*\
      ~~...\
      uncommon"control #sym.arrow.r data"flow\
      ~~pods *exec/attach/port-forward*\
      ~~service/pod/node *proxy*\
    - Change API Server behavior: *CRD, API Services* ...
    - Virtual resources: *TokenReview* ...
  ]
  CRUD + Watch Consistency
  #text(size: 0.8em)[
    - Per-resource *linearizability*
    - No guarantee for watch
  ]
]
// 首先 Kubernetes 的 API 按照 group/version 的方式组织。
// 可以看到图中形成了 group/version/resource 的层级细化路由。
//
// 每个 API group 可以是以下 3 种类型之一：
// - Native APIs: 直接由 API Server 实现的资源类型，像 Pod、Service、Node 等等
// - CRDs: 由用户自定义的资源类型，像 Volcano 的 BatchJob
//   可以通过 customresourcedefinition 配置，里面描述 scheme，table 显示, validation 等等的。自定义程度较弱，但易于使用
// - Aggregated APIs: 由其他组件提供的 API，API Server 只负责转发，不负责持久化，例如 metrics
//   可以通过 apiservices 配置，里面描述了 API group 以及转发到哪个 service。用户可以自定义所有的逻辑
//
//
// Native APIs 相较于 CRD 有额外的功能，我觉得这体现在几个方面
// - 有些资源除了常规的 CRUD 还提供子资源，这些子资源可以是实现某个功能，例如 pods/resize 就是 1.33 加入的 vertical scaling（降本增效的功能）
//   这里有一类很特殊的子资源，它们是少数的从控制面到数据面的流量。我全部列在这里了
//   像节点状态之类的信息也是有 kubelet 主动推送，由 controller 按照 lease 机制来判断节点是否掉线，kube-apiserver 其他情况下 kube-apiserver 不会主动访问 kubelet
//   proxy 就是反代
// - 一些资源能修改 API Server 的行为，像刚才讲到的扩展功能就是这类资源配置的，之后还会讲到 Admission, RBAC, API Priority and Fairness 等等的
// - 还有一些资源是虚拟的，并不持久化，像 TokenReview 资源，它是用来验证 token 的合法性，返回用户信息等
//
// K8s 提供的 per-resource linearizability，保证了对于一个资源所有操作严格按照一个顺序原子化执行，之后在 storage 这块我会更细致将这一块。除了 CRUD 操作外，K8s 还提供了 Watch，Watch 一组资源时，资源间顺序不定，同一资源确保最后一个状态能看到，可能丢失中间事件。（不确定）


== API Sever: APIs (deletion flow example)#footnote[Based on `k8s.io/apiserver/pkg/registry/generic/registry/store.go`]

#slide[
  #image("assets/kube-apiserver-deletion.svg")
][
  - Can be asynchronous
  - Cascade deletion is implemented by *GC Controller*
  - Typical usage
    - *graceful period* Pod
    - *finalizers* PV/PVC
]

// 可以看到 K8s 的删除过程是异步的，单纯看 kube-apiserver 的实现会感觉不明所以，实际上其中的一些
// 逻辑会和外部的 kubelet 和 GC Controller 交互。
//
// 例如 pod 普通删除会有一段 grace Period，API Server 只要看到 gracePeriod 非零就不删除。
// 只是更新这个 metadata 属性而已。实际上这个值会被 kubelet 读取，在 kubelet 终止容器后再由 kubelet 发起一个 gracePeriod 为 0 的删除。
//
// 类似的事情也发生在 finalizer 上，只是 finalize 通常是由 controller 来加上并在删除时移除，来确保它们在删除时进行一些清理操作、或适用于保护资源。
// 特别地是 kubernetes 删除时可以设置 propagationPolicy 来决定资源 own 的其他资源如何删除。
// 默认的行为是 background，就是先删除掉这个资源，然后再删除它 own 的其他资源。
// 可选的还有 foreground，就是先删除它 own 的其他资源，然后再删除这个资源。
// 还有一个 orphan，删除它自己，而后不删除它 own 的资源。
// API Server 在收到 propagationPolicy，其实仅仅是根据 propagationPolicy 设置 finalizer。
// 级联删除以及上面所说的业务逻辑都是由 GC Controller 来删除的。
// GC Controller 会在一个资源的 owner
// 具体来说 ...
//
// 可以看到整体来说删除可能是同步的：这时候 API Server 返回 200 OK。也可以因为 grace period 和
// GC Controller 是异步的，返回 202 Accepted。而这些异步操作的具体逻辑并不会在 API Server 中实现。

== API Server: Middlewares#footnote[Based on `k8s.io/apiserver/pkg/server/config.go`]

#slide(composer: (2fr, 3fr))[
  #numbering("1.", 1) Authentication
  #text(size: 0.8em)[
    - Various methods: *X.509*, *Service Account*, *OIDC* ...
  ]

  #numbering("1.", 2) Audit
  #text(size: 0.8em)[
    - Configured with static Audit Policy
  ]

  #numbering("1.", 3) Priority and Fairness #dimmed[v1.29]
  #text(size: 0.8em)[
    - Controlled by *FrowSchema*
  ]

][
  #numbering("1.", 4) Authorization
  #text(size: 0.8em)[
    - Two methods:\
      ~~*RBAC*\
      ~~*node* #dimmed[(hardcoded for kubelet)]
  ]

  #numbering("1.", 5) Admission
  #text(size: 0.8em)[
    - Two forms:\
      ~~*In-tree Plugin* PodSecurity, NamespaceLifecycle ...\
      ~~*Webhooks*
  ]
]

// 中间件比较多，我们主要关注业务逻辑相关的中间件。像日志、CORS 等等的中间件我们可以先不关注
// 这里我按照处理顺序列出了我认为比较重要的 5 个中间件（从外到里）
//
// 首先是认证。X.509 是把用户信息放在 TLS cert 的 Common Name、Organization 里面.
// 常见的认证结果会有 system:admin，system:node:xx，system:anonymous 等等
//
// 而后 audit 会根据一个静态的配置打印出请求的信息用于审计
// 它的配置主要描述了 动词 + 资源 -> 级别、输出时机 的映射
//
// Priority and Fairness 是 1.29 加入的功能。
// 它的配置主要描述了 用户 + 操作(动词 + 资源) -> 优先级 的映射
// 这个配置是一个 native resources，一般可以是 system:admin 最高优先级，而后控制面的一些组件例如 controller manager，等等组件优先级较高等等
// 在 1.29 之前只有一个笼统的限制 inflight 请求总数的。
//
// Authorization 则是针对不同用户（组）能做什么
// 这里包括用常见的 RBAC native resources 来描述的，还有 hardcode 再代码里面针对 system:node:* kubelet 的鉴权规则。
//
// Admission 则是由一些可选启动的 plugin 组成
// 这里我列了一些常用的，
// PodSecurityAdmission 是 1.25 的一个 feature，可以限制 namespace 提交的 pod 能否拿到 root 等等的权限
// NamespaceLifecycle 则是限制了用户不能往不存在的 namespace 创建 pod，并且保护三个内置的 namespace 不被删除
// 之后会讲到 Namespace Controller，它实现了 namespace 删除时，内部资源的级联删除。这两个组合在一起就构成了 namespace 的 lifecycle。
// 还有就是各种 Webhook，它本身也是以 in-tree 插件的形式存在，它们会读 native resources 来调用具体的接口
// Admission 很特别的一点是它是同步的：如果一个 client 请求创建一个资源，那么 admission 可以一直阻塞它的创建请求。
// 更上层来说，admission 通常是为了实现严格的 per-resource constraint，无法诉诸 eventual consistency 的约束。
// 更复杂的业务逻辑，例如有 deployment 就有 pod 则由 controller 来驱动。

== API Server: Storage

#slide(composer: (3fr, 2fr))[
  How is resource mapped to KV?
  #text(size: 0.8em)[
    - Native: `/registry/<resources>/<namespace>/<name>`
    - CRDs: `/registry/<group>/<resources>/<namespace>/<name>`
  ]

  Features
  #text(size: 0.8em)[
    - MVCC: etcd provides\
      ~~*Get* *List* *Count*\
      ~~*OptimisticPut* *OptimisticDelete*\
      ~~*Watch*\
      `resourceVersion` #sym.arrow.l.r `mod_revision`
    - Encryption at Rest
    - Watch Cache
  ]
][
  Watch Cache
  #text(size: 0.8em)[
    - cache KVs using etcd *Watch*
    - *Stale* #sym.arrow.l.r.double `resourceVersion` $eq.not 0$
    - Accelerate requests\
      ~~*GET (stale)* *LIST (stale)* #dimmed[#sym.lt v1.31]\
      ~~#highlight[*LIST* #dimmed[#sym.gt.eq.slant v1.31 consistent read]] \
      ~~*Watch*
    - Note: filter applies after list etcd
  ]
]

// 首先我第一个好奇的是 K8s 的资源和 etcd 的 key 是怎么一个映射逻辑。
// 大体上,...
// 当然会有一些例外，比如 node 在 etcd 里资源名叫 minions 小黄人、跟班。
// services 叫 service/spec，endpoints 叫 service/endpoints
//
// 存储层提供的功能我列了下大致有这么一些
// 首先是基于多版本的乐观并发控制，用的 resourceVersion 这个字段，它对应到 etcd 的 modRevision 这个字段
// 操作会被翻译成 etcd 的事务，例如一个 PUT with precondition UID，会被翻译成 Get，检查 UID
// 是否一致，一致再进行 OptimisticPut。
// Etcd 提供的 API ...
//
// Encryption at Rest 主要是针对 secret，我们也开启了，会使用 AES 加密。
//
// 我最关心的存储层重头戏其实是 Watch Cache。保证一致性的 cache 是极其困难的，所以很好奇它是怎么实现的
// WATCH cache，我看 deepseek 以及网上的很多资料并不准确
// watch cache 就是 ...
//
// 首先要区分请求类型，指定了 resourceVersion 的读请求就是 stale 读，
// stale 读完全可以从 cache 里面读，如果 cache 不存在，API Server 就会阻塞等待 cache 更新。
// Watch 由于没有本身就是 eventual consistency 的读操作，所以也类似于 stale 读。
//
// 但是 stale 读其实很少，实际上 K8s 很保守，v1.31 之前非 stale 读都是直接打到 etcd 上的。
// 我通过关 etcd 证明了这点。
// 在 etcd 上就是 quorum read。quorum read 的操作成本还是很高的...
// 1.31 引入了一个性能优化让称之为 consistent read
// 实际上 etcd 支持了 WATCH progress，那就可以让 etcd 汇报当前 watch 的最新的 revision。
// 在这之前 K8s 只能被动等待 etcd 推送新的信息。
// API Server 通过一个 Empty Get 请求就能拿到当前一次 quorum read 的 revision。
// watch cache 只需要使用 WATCH progress request (100ms 每次)，然后当 WATCH 的 revision 不小于 quorum read 就可以返回 list 请求了。
//
// GET 请求没有走这个实现方式。反正都要 quorum read 一下，GET 没有必要这样做。
//
// 还需要注意一点，像 label filter/field filter 是在 list 完后才会过滤的。也就是 API Server 与 etcd 交互的流量
// 仅仅取决于你是 namespace-scope list 还是 cluster-scope list


= Component: Controller Manager
