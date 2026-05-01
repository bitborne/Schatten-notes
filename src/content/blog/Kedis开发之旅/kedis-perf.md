---
title: 'Kedis 性能数据记录（不定期更新）'
description: '持续记录 Kedis 的性能指标，每次更新会补充最新测试数据。'
pubDate: 2026-05-01
---

# Kedis 性能数据记录（不定期更新）

## KSF 加载时间

*更新时间: 2026.4.30*

![image-20260501001844138](kedis-perf.assets/image-20260501001844138.png)

## pipeline 性能 --- Redis VS Kedis

*更新时间: 2026.5.1*

![image-20260501113651033](kedis-perf.assets/image-20260501113651033.png)

## AOF 性能(预热后) --- Redis VS Kedis

*更新时间: 2026.4.30*

![image-20260501014217042](kedis-perf.assets/image-20260501014217042.png)

*更新时间: 2026.5.1*

**优化了一下 aof buffer flush 的路径**

![image-20260501132850772](kedis-perf.assets/image-20260501132850772.png)

## RDMA vs sendfile 文件传输

### RDMA send

*soft-RoCE*

![image-20260501120557336](kedis-perf.assets/image-20260501120557336.png)

### sendfile

![image-20260501120523806](kedis-perf.assets/image-20260501120523806.png)
