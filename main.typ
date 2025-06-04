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
  - Deletion might be asynchronous
  - Cascade deletion is implemented by *GC Controller*
  - Typical usage
    - *graceful period* Pod
    - *finalizers* PV/PVC
]

== API Server: Middlewares#footnote[Based on `k8s.io/apiserver/pkg/server/config.go`]

#slide(composer: (2fr, 3fr))[
  Authentication
  #text(size: 0.8em)[
    - Various methods: *X.509*, *Service Account*, *OIDC* ...
  ]

  Audit
  #text(size: 0.8em)[
    - Configured with static Audit Policy
  ]

  Priority and Fairness #dimmed[v1.29]
  #text(size: 0.8em)[
    - Controlled by *FrowSchema*
  ]

][
  Authorization
  #text(size: 0.8em)[
    - Two methods:\
      ~~*RBAC*\
      ~~*node* #dimmed[(hardcoded for kubelet)]
  ]

  Admission
  #text(size: 0.8em)[
    - Two forms:\
      ~~*In-tree Plugin* PodSecurity, NamespaceLifecycle ...\
      ~~*Webhooks*
  ]
]


== API Server: Storage

#slide(composer: (2fr, 3fr))[
  Optimistic concurrency control
  #text(size: 0.8em)[
    - *ResourceVersion*
  ]



][
  Watch Cache
  - consistency read
]

= Component: Controller Manager
