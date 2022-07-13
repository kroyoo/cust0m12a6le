# Graph API

## Applications

### Update application

#### signInAudience


Specifies what Microsoft accounts are supported for the current application. Supported values are:

* `AzureADMyOrg`: Users with a Microsoft work or school account in my organization’s Azure AD tenant (i.e. single tenant)
* `AzureADMultipleOrgs`: Users with a Microsoft work or school account in any organization’s Azure AD tenant (i.e. multi-tenant)
* `AzureADandPersonalMicrosoftAccount`: Users with a personal Microsoft account, or a work or school account in any organization’s Azure AD tenant

upgrade to AzureADandPersonalMicrosoftAccount

```json
{
        "api": {
        "requestedAccessTokenVersion": 2
    },
    "signInAudience": "AzureADandPersonalMicrosoftAccount"
}
```


### Certificates and secrets

#### AddPassword


```json
{
    "passwordCredential": {
        "displayName": "Description",
        "endDateTime": "2399-12-31T00:00:00Z"
    }
}
```
