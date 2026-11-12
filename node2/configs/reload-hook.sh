#!/bin/bash
docker exec nginx nginx -s reload >/dev/null 2>&1 || true
docker restart 3x-ui >/dev/null 2>&1 || true
