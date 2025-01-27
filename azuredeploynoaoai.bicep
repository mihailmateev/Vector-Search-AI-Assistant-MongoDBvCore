@description('Location where all resources will be deployed. This value defaults to the **East US** region.')
@allowed([
  'australiaeast'
  'westeurope'
  'japaneast'
  'uksouth'
  'eastus'
  'eastus2'
  'southcentralus'
])
param location string = 'eastus'

@description('''
Unique name for the deployed services below. Max length 15 characters, alphanumeric only:
- Azure Cosmos DB for MongoDB vCore
- Azure App Service
- Azure Functions

The name defaults to a unique string generated from the resource group identifier.
''')
@maxLength(15)
param name string = uniqueString(resourceGroup().id)

@description('Specifies the SKU for the Azure App Service plan. Defaults to **B1**')
@allowed([
  'B1'
  'S1'
])
param appServiceSku string = 'B1'

@description('Specifies the SKU for the Azure OpenAI resource. Defaults to **S0**')
@allowed([
  'S0'
])
param openAiSku string = 'S0'

@description('MongoDB vCore user Name. No dashes.')
param mongoDbUserName string

@description('MongoDB vCore password. 8-256 characters, 3 of the following: lower case, upper case, numeric, symbol.')
@minLength(8)
@maxLength(256)
@secure()
param mongoDbPassword string

@description('Specifies the Azure OpenAI account name.')
param openAiAccountName string = ''

@description('Specifies the key for Azure OpenAI account.')
@secure()
param openAiAccountKey string = ''

@description('Specifies the deployed model name for your Azure OpenAI account completions API (GPT 4).')
param openAiCompletionsModelName string = ''

@description('Specifies the deployed model name for your Azure OpenAI account embeddings API.')
param openAiEmbeddingsModelName string = ''


@description('Git repository URL for the application source. This defaults to the [`Azure/Vector-Search-Ai-Assistant`](https://github.com/Azure/Vector-Search-AI-Assistant-MongoDBvCore.git) repository.')
param appGitRepository string = 'https://github.com/mihailmateev/Vector-Search-AI-Assistant-MongoDBvCore.git'

@description('Git repository branch for the application source. This defaults to the [**main** branch of the `Azure/Vector-Search-Ai-Assistant-MongoDBvCore`](https://github.com/Azure/Vector-Search-AI-Assistant-MongoDBvCore/tree/main) repository.')
param appGetRepositoryBranch string = 'main'

var deployedRegion = {
  'East US': {
    armName: toLower('eastus')
  }
  'South Central US': {
    armName: toLower('southcentralus')
  }
  'West Europe': {
    armName: toLower('westeurope')
  }
}

var openAiSettings = {
  accountName: openAiAccountName
  accountKey: openAiAccountKey
  endPoint: 'https://${openaiAccountName}.openai.azure.com/'
  sku: openAiSku
  maxConversationTokens: '100'
  maxCompletionTokens: '500'
  completionsModel: {
    name: 'gpt-4'
    version: '0613'
    deployment: {
      name: openAiCompletionsModelName
    }
  }
  embeddingsModel: {
    name: openAiEmbeddingsModelName
    version: '2'
    deployment: {
      name: openAiEmbeddingsModelName
    }
  }

var mongovCoreSettings = {
  mongoClusterName: '${name}-mongo'
  mongoClusterLogin: mongoDbUserName
  mongoClusterPassword: mongoDbPassword
}

var appServiceSettings = {
  plan: {
    name: '${name}-web-plan'
    sku: appServiceSku
  }
  web: {
    name: '${name}-web'
    git: {
      repo: appGitRepository
      branch: appGetRepositoryBranch
    }
  }
  function: {
    name: '${name}-function'
    git: {
      repo: appGitRepository
      branch: appGetRepositoryBranch
    }
  }
}

resource mongoCluster 'Microsoft.DocumentDB/mongoClusters@2023-09-15-preview' = {
  name: mongovCoreSettings.mongoClusterName
  location: location
  properties: {
    administratorLogin: mongovCoreSettings.mongoClusterLogin
    administratorLoginPassword: mongovCoreSettings.mongoClusterPassword
    serverVersion: '5.0'
    nodeGroupSpecs: [
      {
        kind: 'Shard'
        sku: 'M30'
        diskSizeGB: 128
        enableHa: false
        nodeCount: 1
      }
    ]
  }
}

resource mongoFirewallRulesAllowAzure 'Microsoft.DocumentDB/mongoClusters/firewallRules@2023-09-15-preview' = {
  parent: mongoCluster
  name: 'allowAzure'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource mongoFirewallRulesAllowAll 'Microsoft.DocumentDB/mongoClusters/firewallRules@2023-09-15-preview' = {
  parent: mongoCluster
  name: 'allowAll'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: appServiceSettings.plan.name
  location: location
  sku: {
    name: appServiceSettings.plan.sku
  }
}

resource appServiceWeb 'Microsoft.Web/sites@2022-03-01' = {
  name: appServiceSettings.web.name
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: '${name}fnstorage'
  location: location
  kind: 'Storage'
  sku: {
    name: 'Standard_LRS'
  }
}

resource appServiceFunction 'Microsoft.Web/sites@2022-03-01' = {
  name: appServiceSettings.function.name
  location: location
  kind: 'functionapp'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      alwaysOn: true
    }
  }
  dependsOn: [
    storageAccount
  ]
}

resource appServiceWebSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: appServiceWeb
  name: 'appsettings'
  kind: 'string'
  properties: {
    APPINSIGHTS_INSTRUMENTATIONKEY: appServiceWebInsights.properties.InstrumentationKey
    OPENAI__ENDPOINT: openAiSettings.endPoint
    OPENAI__KEY: openAiSettings.accountKey
    OPENAI__EMBEDDINGSDEPLOYMENT: openAiSettings.embeddingsModel.deployment.name
    OPENAI__COMPLETIONSDEPLOYMENT: openaisettings.completionsModel.deployment.name
    OPENAI__MAXCONVERSATIONTOKENS: openAiSettings.maxConversationTokens
    OPENAI__MAXCOMPLETIONTOKENS: openAiSettings.maxCompletionTokens
    MONGODB__CONNECTION: 'mongodb+srv://${mongovCoreSettings.mongoClusterLogin}:${mongovCoreSettings.mongoClusterPassword}@${mongovCoreSettings.mongoClusterName}.mongocluster.cosmos.azure.com/?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000'
    MONGODB__DATABASENAME: 'retaildb'
    MONGODB__COLLECTIONNAMES: 'product'
    MONGODB__MAXVECTORSEARCHRESULTS: '10'
  }
}

resource appServiceFunctionSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: appServiceFunction
  name: 'appsettings'
  kind: 'string'
  properties: {
    AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${name}fnstorage;EndpointSuffix=core.windows.net;AccountKey=${storageAccount.listKeys().keys[0].value}'
    APPLICATIONINSIGHTS_CONNECTION_STRING: appServiceFunctionsInsights.properties.ConnectionString
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
    OPENAI__ENDPOINT: openAiSettings.endPoint
    OPENAI__KEY: openAiSettings.accountKey
    OPENAI__EMBEDDINGSDEPLOYMENT: openAiSettings.embeddingsModel.deployment.name
    OPENAI__MAXTOKENS: '8191'
    MONGODB__CONNECTION: 'mongodb+srv://${mongovCoreSettings.mongoClusterLogin}:${mongovCoreSettings.mongoClusterPassword}@${mongovCoreSettings.mongoClusterName}.mongocluster.cosmos.azure.com/?tls=true&authMechanism=SCRAM-SHA-256&retrywrites=false&maxIdleTimeMS=120000'
    MONGODB__DATABASENAME: 'retaildb'
    MONGODB__COLLECTIONNAMES: 'product'
  }
}

resource appServiceWebDeployment 'Microsoft.Web/sites/sourcecontrols@2021-03-01' = {
  parent: appServiceWeb
  name: 'web'
  properties: {
    repoUrl: appServiceSettings.web.git.repo
    branch: appServiceSettings.web.git.branch
    isManualIntegration: true
  }
  dependsOn: [
    appServiceWebSettings
  ]
}

resource appServiceFunctionsDeployment 'Microsoft.Web/sites/sourcecontrols@2021-03-01' = {
  parent: appServiceFunction
  name: 'web'
  properties: {
    repoUrl: appServiceSettings.web.git.repo
    branch: appServiceSettings.web.git.branch
    isManualIntegration: true
  }
  dependsOn: [
    appServiceFunctionSettings
  ]
}

resource appServiceFunctionsInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appServiceFunction.name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource appServiceWebInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appServiceWeb.name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

output deployedUrl string = appServiceWeb.properties.defaultHostName
