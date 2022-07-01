# Tips
## Please check the version dependency

### ckeck opensty offical nginx_version
```bash

for name in $(ls -l | grep ^- | awk '{print $9}')
do
   cat $name | grep "nginx_version"
done


````
