Creating the docker image base:
```
docker build --platform linux/arm/v7 -t kalibuild:latest -f Dockerfile.build .
```