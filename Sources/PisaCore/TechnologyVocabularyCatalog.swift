enum TechnologyVocabularyCatalog {
    // Each row is canonical spelling | mode | aliases (separated by semicolons).
    // + derives spoken letter names. ? requires a technical cue for spoken
    // aliases with a common meaning. c requires an adjacent company/service cue.
    // ic also permits regular Russian case endings for that company name.
    // w requires a technical cue only for English spoken aliases; i permits
    // observed endings on a company name. h hides an entry from term candidates.
    // Flags can be combined (e.g. ic).
    // = marks a written alias with exact case. ~ requires a personal entry.
    // Plain written terms are useful for extraction even without spoken aliases.
    static let entries = """
    # Markets, strategy and leadership
    B2B|+|бетуби;би 2 би;би два би;бэ два бэ;=Б2Б;=B2В;=В2В;=b2b
    B2C|+|битуси;битуци;би 2 си;би два си;бэ два си;би два цэ;бэ два цэ;=Б2Ц;=Б2С;=B2С;=Б2C;=В2С;=В2C;=b2c
    B2G|+|битуджи;би 2 джи;би два джи;бэ два джи;=Б2Г
    B2E|+|би ту и
    D2C|+|ди 2 си;ди два си
    B2B2C|+
    C2C|+|си 2 си
    P2P|+|пи 2 пи
    C2B|+
    G2B|+
    B2B SaaS||би ту би саас
    SaaS||саас;эс эй эй эс
    PaaS||паас;пи эй эй эс
    IaaS||иаас;ай эй эй эс
    DaaS||даас
    FaaS||фаас
    white-label|w|вайт лейбл;вайт лэйбл;вайт лейбел;уайт лейбл;white label;=white‑label;=white‐label
    private label||прайвет лейбл;прайвит лейбл
    GTM|+|гэ тэ эм
    PMF|+|пэ эм эф
    ICP|+
    TAM|+|тэ а эм
    SAM|+|эс а эм
    SOM|+|эс о эм
    CAGR|+|кагр
    QoQ||кью оу кью
    YoY||йоу вай;уай оу уай
    MoM||эм оу эм
    LTV|+|эл тэ вэ
    CAC|+|си эй си
    ROAS|+|роас
    ARR|+|эй ар ар
    MRR|+|эм ар ар
    ARPU|+|арпу
    ARPPU|+|арппу
    GMV|+|гэ эм вэ
    EBITDA||эбитда;ебитда
    EBIT|+|эбит
    EBITDAR||эбитдар
    OPEX||опекс;опэкс;=OpEx
    CAPEX||капекс;капэкс;=CapEx
    P&L||пи эн эл;пи энд эл;пи эн эль;пи энд эль;=PNL
    FCF|+
    NPV|+
    IRR|+
    DCF|+
    ROI|+|эр о ай
    COGS||когс
    KPI|+|ка пэ и;кей пи ай;кэй пи ай;ка пи ай;=КПИ
    OKR|+|о кей ар;о ка эр;оу кей эр;о кей эр
    CEO|+
    CPO|+
    PO|+|пи о;=P-O;=P‑O
    PM|+
    IT|+
    HR|+|эйч эр
    GR|+|джи эр
    CTO|+
    COO|+
    CFO|+
    CMO|+
    CDO|+
    CIO|+
    CISO|+|сисо
    CHRO|+
    CRO|+
    CCO|+
    CSO|+
    CTPO|+
    VP|+
    SVP|+
    EVP|+
    C-suite||си сюит;си свит;=C‑suite
    C-level||си левел;си лэвел;=C‑level
    board of directors
    steering committee||стиринг комити;стиринг коммити
    governance model
    succession planning
    operating model
    QBR|+
    MBR|+
    executive summary||экзекьютив саммари;экзекьютив самэри
    span of control
    headcount planning
    target operating model
    IPO|+|и пэ о
    M&A||эм энд эй;эм эн эй
    NDA|+|эн дэ а
    R&D||ар энд ди;ар эн ди
    SMB|+
    SME|+
    POS|+
    KYC|+
    AML|+
    BNPL|+
    PCI DSS||пи си ай ди эс эс
    SWOT||свот
    PESTEL||пестел
    NPS|+|эн пэ эс
    CRM|+|си эр эм;цэ эр эм
    CSAT||сисат;си сэт;си эс эй ти
    CES|+
    eNPS||иэн пи эс;иэнпиэс
    DAU||дау;ди эй ю
    WAU||дабл ю эй ю
    MAU||мау;эм эй ю
    DORA
    AAARRR
    AARRR
    north star metric||норс стар метрик;норт стар метрик
    go-to-market||гоу ту маркет;гоу ту маркэт;go to market
    product-market fit||продакт маркет фит;product market fit
    total addressable market
    unit economics||юнит экономика
    cohort analysis
    market fit
    jobs to be done||джобс ту би дан
    working backwards
    design thinking||дизайн синкинг;дизайн тикинг
    decision log||десижн лог
    product strategy
    product discovery||продакт дискавери
    product delivery||продакт деливери
    customer journey map
    impact mapping||импакт мэппинг
    opportunity solution tree
    customer development||кастомер девелопмент
    design sprint
    user story||юзер стори
    user research
    use case||юз кейс
    growth loop
    win rate||вин рейт
    churn rate||чёрн рейт;черн рейт
    retention rate
    activation rate
    conversion rate
    # Finance and investment
    IFRS|+
    GAAP|+
    WACC|+|вакк;уакк
    EPS|+
    ROE|+
    ROA|+
    ROIC|+
    ROCE|+
    EBT|+
    EV/EBITDA
    EV/Sales
    LBO|+
    MBO|+
    AUM|+
    NAV|+
    SPV|+
    TTM|+
    LTM|+
    YTD|+
    DSO|+
    DIO|+
    DSCR|+
    take rate||тейк рейт;тэйк рейт
    burn rate||бёрн рейт;берн рейт
    run rate||ран рейт
    cash runway||кэш ранвей;кеш ранвей
    cash flow||кэш флоу;кеш флоу
    free cash flow||фри кэш флоу;фри кеш флоу
    cash conversion cycle
    working capital
    enterprise value
    contribution margin
    gross margin
    break-even point
    discount rate
    due diligence||дью дилидженс;дю дилидженс;дью дилиджэнс
    data room||дата рум;дэйта рум
    term sheet||терм шит;тёрм шит
    cap table||кап тейбл;кэп тейбл;кэп тэйбл
    earn-out||ёрн аут;ерн аут;earn out
    оборотный капитал
    кассовый разрыв
    валовая маржа
    операционная прибыль
    точка безубыточности
    дисконтированный денежный поток
    # Product, analytics and working methods
    Q1|h|кью один;кью 1;=q1
    Q2|h|кью два;кью 2;=q2
    Q3|h|кью три;кью 3;=q3
    Q4|h|кью четыре;кью 4;=q4
    roadmap|h|роудмап;роадмап
    challenge|h|челлендж
    MVP|+|эм вэ пэ
    MLP|+
    MMP|+
    PRD|+|пэ эр дэ;пи эр ди
    BRD|+|бэ эр дэ
    FRD|+
    RFC|+
    ADR|+
    RACI||раси;рэйси;рэйсай
    RICE
    ICE
    MoSCoW
    JTBD|+|джей ти би ди
    CJM|+|си джи эм;си джей эм
    UX|+|ю икс;юэкс
    UI|+|ю ай
    HADI
    FMEA|+
    QA|+|ку а
    UAT|+
    KPI tree
    feature flag||фича флаг;фиче флаг;фичер флаг
    feature toggle
    change request
    peer review
    code review||код ревью
    tech debt||тех долг
    acceptance criteria
    backlog refinement
    product backlog
    product ownership||продакт оунершип;продакт оунэршип
    experiment design
    AOV|+
    CTR|+
    CPC|+
    CPM|+
    CPA|+
    CUPED||кьюпед;кьюпэд
    time to value||тайм ту вэлью;тайм ту велью
    cohort retention
    revenue retention
    sprint planning
    story points
    incident review
    blameless postmortem
    A/B||эй би;=А/Б
    A/B-тест||эй би тест;а бе тест;=А/Б-тест;=A/B test;=AB-тест
    A/B-тестирование||эй би тестирование;=А/Б-тестирование
    # Software architecture, development, interfaces and platforms
    API|+|апи;а пи ай;а пэ и;эй пи и;=АПИ
    SDK|+|эс дэ ка;эс де ка;эс ди ка;эс дэ кей
    IDE|+|ай ди и
    GUI|+|джи ю ай
    TUI|+
    CLI|+
    JIT|+
    AOT|+
    ECMAScript||экмаскрипт;экма скрипт
    JavaScript||джава скрипт;жава скрипт;=Javascript
    TypeScript||тайп скрипт;тайпскрипт;=Typescript
    CPython||си пайтон;си питон
    Python||пайтон;пай тон
    Java||джава
    Kotlin|?|котлин
    SwiftUI||свифт ю ай
    Objective-C||обджектив си;объектив си
    C++||си плюс плюс
    C#||си шарп
    F#||эф шарп
    .NET||дот нет;дотнэт;дотнет
    iOS||ай оу эс;ай ос;айос
    iPadOS||айпад оу эс;айпад ос
    macOS||мак ос;мак оу эс;макось;=MacOS
    watchOS||вотч ос
    Android|?|андроид
    WebAssembly||веб ассембли;вебассембли
    WASM||васм;уасм
    JVM|+
    JDK|+
    JVM bytecode
    GC|+
    OOP|+|о о пэ
    SOLID
    DRY
    KISS
    YAGNI||ягни
    TDD|+
    BDD|+
    DDD|+
    CQRS|+
    ORM|+
    CRUD||круд;крад;си ар ю ди
    RPC|+|эр пэ цэ
    gRPC||джи ар пи си;джи эр пэ цэ
    REST|+|рэст
    REST API||рэст апи;рест апи
    API gateway||апи гейтвей;эй пи ай гейтвей
    API contract||апи контракт;эй пи ай контракт
    BFF|+
    OpenAPI||оупен эй пи ай;опен апи
    GraphQL||граф кью эл;граф ку эл;граф кью эль
    JSON|?|джейсон;джей сан
    JSON Schema||джейсон схема
    XML|+|икс эм эль
    YAML||ямл;ямэль
    TOML||томл
    HTML|+|аш тэ эм эль
    CSS|+|цэ эс эс
    DOM|+
    SVG|+
    SSR|+
    CSR|+
    SPA|+
    PWA|+
    WebSocket||веб сокет;вэб сокет
    WebRTC||веб ар ти си
    HTTP|+|аш тэ тэ пэ
    HTTPS|+|аш тэ тэ пэ эс
    HTTP/2||аш тэ тэ пэ два;эйч ти ти пи ту
    HTTP/3||аш тэ тэ пэ три
    URL|+|у эр эль
    URI|+
    CDN|+|цэ дэ эн
    DNS|+|дэ эн эс
    TCP|+|тэ цэ пэ
    UDP|+|у дэ пэ
    IP|+|ай пи
    IPv4||ай пи ви фор;ай пи версии четыре
    IPv6||ай пи ви сикс;ай пи версии шесть
    UDP/IP
    TCP/IP
    DHCP|+
    NAT|+
    CORS||корс
    TLS|+|тэ эль эс
    SSL|+
    QUIC
    CDN cache
    RxJS||ар икс джей эс
    Next.js||некст джей эс;некст джи эс
    Node.js||нод джей эс;ноуд джей эс
    React Native||реакт нейтив;реэкт нэйтив
    Spring Boot||спринг бут
    Jetpack Compose||джетпак компоуз
    Xcode||икс код;икскод
    VS Code||ви эс код;ви эс коуд
    Visual Studio||вижуал студио
    npm|+|эн пи эм
    pnpm|+|пи эн пи эм
    Webpack||вебпак
    TypeScript compiler
    GitHub||гит хаб;гитхаб
    GitLab||гит лаб;гитлаб
    Bitbucket||битбакет;бит бакет
    GitHub Actions||гитхаб экшнс;гит хаб экшенс
    merge request||мёрдж реквест;мердж реквест
    pull request||пул реквест;пулл реквест
    draft pull request||драфт пул реквест;драфт пулл реквест
    CODEOWNERS
    trunk-based development||транк бейст девелопмент;trunk based development
    GitFlow||гит флоу;гитфлоу
    release train||релиз трейн;релиз трэйн
    semantic versioning||семантик версионинг
    backward compatibility
    breaking change||брейкинг чейндж;брэйкинг чэйндж
    idempotency key
    event-driven architecture
    event sourcing||ивент сорсинг;ивэнт сорсинг
    transactional outbox
    circuit breaker||сёркит брейкер;серкит брейкер
    dependency injection||депенденси инджекшен;дипенденси инджекшн
    контрактное тестирование
    интеграционное тестирование
    регрессионное тестирование
    monorepo
    monorepository
    # Infrastructure, quality, security and operations
    CI/CD||си ай си ди;си ай и си ди;це и це де
    CD pipeline
    E2E testing||и ту и тестинг
    smoke test||смоук тест
    load testing
    chaos engineering||кейос инжиниринг
    release candidate||релиз кандидат
    canary deployment||канари деплоймент;кэнери деплоймент
    blue-green deployment||блю грин деплоймент;blue green deployment
    progressive delivery
    канареечный релиз
    staged rollout
    dead letter queue
    DLQ|+
    error budget||эррор баджет;эрор баджет
    on-call rotation
    distributed tracing
    distributed lock
    disaster recovery
    IaC||ай эй си
    DevOps||девопс;дев опс;=Devops
    DevSecOps||дев сек опс;девсекопс
    FinOps||фин опс;финопс
    SRE|+
    SLA|+|эс эль а
    SLI|+
    SLO|+
    MTTR|+
    MTBF|+
    MTTD|+
    RTO|+
    RPO|+
    PoC||пи оу си
    QoS||кью оу эс
    Docker|?|докер
    Dockerfile||докер файл
    Kubernetes||кубернетес;кубернетис;кубернетэс
    K8s||кей эйт эс;ка восемь эс;=K8S
    Helm||хелм;хэльм
    Terraform||терраформ;терра форм
    Prometheus||прометеус
    Grafana||графана
    OpenTelemetry||опен телеметри;оупен телеметри
    OTel||оу тел
    RabbitMQ||рэббит эм кью;раббит эм кью
    Kafka
    Apache Kafka||апачи кафка
    Kubernetes operator
    GitOps||гит опс;гитопс
    RBAC||ар бак;эр бак;ар би эй си
    ABAC||эй бак;эй би эй си
    IAM|+|аи эм
    SSO|+
    SAML||самл;эс эй эм эл
    OAuth||оу аут;о аут;оауз
    OAuth 2.0
    OIDC|+
    WebAuthn||веб аут эн;вэб аут эн
    mTLS||эм ти эл эс
    JWT|+|джей дабл ю ти
    MFA|+|эм эф а
    2FA||два эф а;ту эф эй;два эф эй
    TOTP|+
    SAST|+
    DAST|+
    SBOM||эс бом;эс би оу эм
    SIEM||сиэм;эс ай и эм
    SOC|+
    XSS|+
    CSRF|+
    CVE|+
    CVSS|+
    WAF|+
    DDoS||дедос;ди дос;=DDOS
    GDPR|+
    ISO 27001
    SOC 2
    zero trust||зиро траст
    least privilege
    data residency
    software supply chain
    # Data, machine learning and AI
    BI|+|би ай
    DWH|+
    ETL|+|етл;этл
    ELT|+
    OLTP|+
    OLAP||олап
    Data Vault
    data lake||дата лейк;дата лэйк
    data warehouse||дата вэрхаус;дэйта вэрхаус;дата веархаус
    data pipeline||дата пайплайн;дэйта пайплайн
    data lineage||дата линидж;дэйта линидж
    data catalog
    data quality
    change data capture
    feature store||фича стор;фичер стор
    data mesh||дата меш;дэйта меш
    lakehouse||лейкхаус;лейк хаус
    SQL|+|эс ку эль;эс кью эл;эс ку эл;сиквел
    NoSQL||ноу сиквел;ноу эс кью эл;ноу эс ку эль
    T-SQL||ти эс кью эл
    PostgreSQL||постгрес кью эл;постгрес ку эль;постгре эс кью эл
    Postgres||постгрес
    MySQL||май сиквел;май эс кью эл;май эс ку эль
    SQLite||эс кью эл лайт;эс ку эль лайт;сиквелайт
    pgvector||пи джи вектор
    Redis
    ClickHouse||кликхаус;клик хаус;=Clickhouse
    MongoDB||монго ди би;монгодиби
    DuckDB||дак ди би;дак диби
    BigQuery||биг квери;биг куэри
    Airflow||эйрфлоу;эйр флоу
    dbt|+|ди би ти
    pandas
    NumPy||нампай;нам пай
    PyTorch||пайторч;пай торч
    TensorFlow||тензорфлоу;тензор флоу
    Hugging Face||хаггинг фейс;хагинг фейс
    AI|+|эй ай
    AGI|+
    ML|+
    MLX|+
    MLOps||эм эл опс;эмэльопс;млопс
    LLMOps||эл эл эм опс
    NLP|+
    NLU|+
    NLG|+
    ASR|+
    STT|+
    TTS|+
    OCR|+
    LLM|+|эл эл эм;эль эль эм
    SLM|+
    VLM|+
    GPT|+|джи пи ти
    GPT-4||джи пи ти четыре;джи пи ти фор
    ChatGPT||чат джи пи ти;чат джипити
    RAG||рэг;ар эй джи
    LoRA
    QLoRA||кью лора
    RLHF|+
    DPO|+
    SFT|+
    MCP|+|эм цэ пэ
    ONNX||онникс;оннх
    CUDA
    GPU|+|джи пи ю
    CPU|+
    BTB|+
    TPU|+
    NPU|+
    Metal Performance Shaders
    fine-tuning||файн тюнинг;файнтьюнинг
    prompt engineering||промпт инжиниринг
    vector database
    function calling
    mixture of experts
    retrieval-augmented generation
    context window||контекст виндоу
    structured output||стракчурд аутпут
    tool calling||тул коллинг;тул колинг
    model serving
    prompt injection||промпт инджекшен;промпт инджекшн
    # Common tools and platforms
    Figma||фигма
    Jira||джира
    Confluence||конфлюенс;конфлуенс
    YouTrack||ютрек;ю трек
    JetBrains||джетбрейнс;джет брейнс
    TensorRT||тензор ар ти
    Google Cloud||гугл клауд
    AWS|+
    GCP|+
    Amazon Web Services
    Microsoft Azure||майкрософт ажур;майкрософт эжур
    Azure DevOps
    OpenSearch||оупен сёрч;опен серч
    Elasticsearch||эластиксёрч;эластик серч
    Sentry
    Keycloak||киклоак;ки клоук
    TeamCity||тимсити;тим сити
    Mattermost||маттермост;мэттермост
    Rocket.Chat||рокет чат
    Yandex Cloud||яндекс клауд
    YandexGPT||яндекс джи пи ти
    GigaChat||гига чат;гигачат
    GigaCode||гига код
    VK Cloud||вк клауд
    AppMetrica||апп метрика;апметрика;эпметрика
    RuStore||рустор;ру стор
    YCLIENTS||=YClients
    # International technology companies and products
    Microsoft||майкрософт;микрософт
    Google||гугл;гоогл
    Apple||эппл;эпл;аппл
    Amazon||амазон;эмазон
    Alphabet|c|алфабет;альфабет
    Meta|c|мета
    Facebook||фейсбук;фэйсбук;фейс бук
    Instagram||инстаграм;инстаграмм
    WhatsApp||вотсап;ватсап;вацап;уотсап;вотс апп
    Telegram||телеграм
    TikTok||тикток;тик ток
    YouTube||ютуб;ю туб;ютьюб;ю тьюб
    LinkedIn||линкедин;линкед ин;линкдин;линктин
    Reddit||реддит;реддитт
    Pinterest||пинтерест;пинтрест
    Snapchat||снэпчат;снапчат;снэп чат
    Discord||дискорд
    Twitch||твич
    Netflix||нетфликс;нэтфликс
    Spotify||спотифай;спотифаи
    Salesforce||сейлс форс;сэйлс форс;сейлз форс
    Oracle||оракл;оракэл
    Adobe||адоби;адобе;эдоуби
    Cisco||циско;сиско
    Intel||интел;интэл
    IBM|+|ай би эм;и бэ эм
    SAP|+|эс а пэ
    HP||эйч пи
    HPE|+
    Dell||делл;дэлл
    Lenovo||леново
    Samsung||самсунг;сэмсунг
    Huawei||хуавей;хуавэй
    Xiaomi||сяоми;шаоми;ксиаоми
    HONOR|c|хонор;онор
    OnePlus||ван плас;уан плас
    Qualcomm||квалком;куалком
    Broadcom||бродком;броудком
    MediaTek||медиатек;медиа тек
    ASML|+
    TSMC|+|ти эс эм си
    ASUS||асус;эйсус
    ASUSTeK||асустек
    Acer||эйсер;асер
    AMD|+
    NVIDIA||энвидиа;энвидия;нвидиа
    Arm|c|арм;=ARM
    Alibaba||алибаба
    AliExpress||алиэкспресс;али экспресс
    Tencent||тенсент;тэнсент
    Baidu||байду
    ByteDance||байт дэнс;байт денс;байтдэнс
    JD.com||джей ди ком
    Rakuten||ракутен
    Sony||сони
    Nintendo||нинтендо
    Ubisoft||юбисофт;убисофт
    Epic Games||эпик геймс;эпик гэймс
    Riot Games||райот геймс;райот гэймс
    PayPal||пэйпал;пейпал;пэй пал
    Stripe||страйп
    Shopify||шопифай
    Adyen||адьен;адйен
    Wise|c|вайз
    Revolut||револют
    Nubank||нюбанк;ну банк
    Klarna||кларна
    Plaid||плэд
    Block|c|блок
    Mastercard||мастеркард;мастер кард
    Visa|c|виза
    Zoom|c|зум
    Slack||слэк;слэкк;слак
    Dropbox||дропбокс;дроп бокс
    Notion||ноушен;ноушн;ноушэн
    Atlassian||атлассиан;атлассиэн
    Asana|c|асана
    Trello||трелло
    Miro|c|миро
    monday.com||мандей ком;мандэй ком
    Airtable||эйртейбл;эйр тейбл
    Canva||канва;кэнва
    Lucid Software||люсид софтвер
    HubSpot||хабспот;хаб спот
    ServiceNow||сервис нау;сёрвис нау;сервисноу
    Workday||воркдей;ворк дей
    Zendesk||зендеск;зэн деск
    Docusign||докусайн;доку сайн;=DocuSign
    Cloudflare||клаудфлэр;клауд флер
    Akamai||акамай
    Fastly||фастли;фэстли
    Red Hat||ред хат;рэд хэт
    SUSE||сюзе;сузе
    Canonical|c|каноникал
    VMware||ви эм вар;ви эм вээр;ви эм вэр
    HashiCorp||хашикорп;хаши корп
    DigitalOcean||диджитал оушен;диджитал оушн
    Hetzner||хетцнер;хецнер
    OVHcloud||о ви эйч клауд;о вэ аш клауд
    Datadog||датадог;дата дог
    Databricks||датабрикс;дата брикс
    Snowflake||сноуфлейк;сноуфлэйк;сноу флейк
    Confluent||конфлуэнт;конфлюэнт
    Elastic|c|эластик
    Splunk||спланк;сплунк
    Fortinet||фортинет;форти нет
    Palo Alto Networks||пало альто нетворкс;пало алто нетворкс
    CrowdStrike||краудстрайк;крауд страйк
    Check Point||чек пойнт;чекпоинт
    Zscaler||зи скейлер;зед скейлер
    OpenAI||оупен эй ай;опен эй ай;опен аи
    DeepMind||дип майнд;дипмайнд
    DeepSeek||дип сик;дипсик
    Anthropic||антропик
    Mistral AI||мистраль эй ай;мистрал эй ай
    Perplexity||перплексити;пёрплексити
    ElevenLabs||илевен лабс;элевен лабс;илевен лэбс
    Cohere||кохир;кохирэ
    # Russian technology companies and products
    Яндекс||яндекс;=Yandex
    VK||вэ ка;ви кей;=ВК
    ВКонтакте||вконтакте
    Сбер||сбер
    Сбербанк||сбербанк;сбер банк
    Т-Банк||тэ банк;те банк;т банк;=Т‑Банк;=Т‐Банк
    Тинькофф||тинькофф;=Tinkoff
    Авито||авито;=Avito
    HeadHunter|ic|хэд хантер;хед хантер;хит хантер;=Headhunter
    Otello|c|отелло;отэлло;отелла;отэлла;=Otella;=otello
    Ozon|c|озон
    Wildberries||вайлдберриз;вайлд берриз;вайлдберрис;валдберис;вайлдберис
    RWB||эр дабл ю би;эр вэ бэ
    Контур|c|контур
    Точка|c|точка
    Мир|c|мир
    Positive Technologies||позитив текнолоджиз;позитив технолоджис;позитив технолоджиз;=Позитив Текнолоджиз
    Лаборатория Касперского||лаборатория касперского
    Kaspersky|c|касперский
    РЕД СОФТ||рэд софт;ред софт;=РЕД Софт
    РЕД ОС||рэд ос;ред ос
    МойОфис||мойофис
    Группа Астра||группа астра
    Astra Linux||астра линукс;астра линакс
    ГК Астра||гэ ка астра
    Ростелеком||ростелеком;рос телеком;=Rostelecom
    МТС||эм тэ эс;мтс;=MTS
    МегаФон||мегафон;=MegaFon
    билайн||билайн;би лайн;=Билайн;=Beeline
    T2||тэ два;=Т2
    Naumen||наумен;=NAUMEN
    ЛАНИТ||ланит;=LANIT
    IBS|+|ай би эс;и бэ эс
    КРОК|c|крок;=CROC
    1С||один эс;один цэ;=1C
    Битрикс24||битрикс двадцать четыре;битрикс 24;=Bitrix24
    СКБ Контур||эс ка бэ контур;скб контур
    ИнфоТеКС||инфотекс;инфо текс
    Код Безопасности|c|код безопасности
    UserGate||юзергейт;юзер гейт
    F.A.C.C.T.|c|факт
    BI.ZONE||би зона;би зон;би зоун
    Selectel||селектел;селектэл
    Timeweb||таймвеб;тайм веб
    Cloud.ru||клауд ру;клаудру
    Softline||софтлайн;софт лайн
    ГК Softline||гэ ка софтлайн
    АйТеко||ай теко;айтеко
    Т1||тэ один;тэ 1;=T1
    МТС Линк||мтс линк;эм тэ эс линк
    VK Tech||ви кей тек;вэ ка тек
    Циан||циан;=CIAN
    Домклик||домклик;дом клик
    Самокат|c|самокат
    Купер|c|купер
    СДЭК||сдэк;сдек
    2ГИС||ту гис;~два гис;~дву гис;~двух гис;~2 ги;~два гес;~два гиз;=2GIS
    """
}
