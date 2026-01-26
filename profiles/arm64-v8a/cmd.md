Creating the docker image base:
```
docker build --platform linux/arm64 -t kalibuild:latest-64 -f Dockerfile.build .
```