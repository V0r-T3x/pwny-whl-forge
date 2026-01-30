Creating the docker image base:
```
docker build --platform linux/arm/v6 -t kalibuild_v6:latest -f Dockerfile.build .
```