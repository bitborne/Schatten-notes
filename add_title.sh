#!/bin/bash

find src/content/blog -name "*.md" | while read file; do
  # 获取文件名（不带扩展名）作为标题
  title=$(basename "$file" .md)
  # 获取当前日期
  date=$(date +%Y-%m-%d)

  # 检查是否已有 frontmatter
  if ! head -1 "$file" | grep -q "^---"; then
    # 添加 frontmatter
    temp=$(mktemp)
    cat >"$temp" <<EOF
---
title: '$title'
description: ''
pubDate: $date
---

EOF
    cat "$file" >>"$temp"
    mv "$temp" "$file"
  fi
done
