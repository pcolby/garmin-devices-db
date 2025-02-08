

Example:

```sh
jq -c '.[].skus.[]|select(.specs["Full vector map"] == "yes")|{productName, productId, partNumber}' products-en-AU.json
```
