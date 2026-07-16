import { useEffect, useState } from 'react'

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:8000'

const SEGMENT_DESCRIPTIONS = {
  Champions: 'Compraram recentemente, com alta frequência e alto valor — a base mais valiosa.',
  Loyal: 'Compram com frequência e bom valor, mesmo sem uma compra recente.',
  'At Risk': 'Já foram bons compradores, mas estão sem comprar há um tempo.',
  Promising: 'Compraram recentemente, mas ainda com pouca frequência ou valor.',
  Lost: 'Sem comprar há muito tempo, com baixa frequência e baixo valor histórico.',
  Hibernating: 'Comportamento misto, sem se destacar em recência, frequência ou valor.',
  no_purchase: 'Ainda não realizaram nenhuma compra.',
}

const USE_CASES = [
  {
    title: 'Segmentação inteligente',
    features: 'total_orders, net_revenue, avg_order_value, recency_days',
    algorithm: 'K-Means (k escolhido via silhouette score) sobre métricas RFM.',
  },
  {
    title: 'Melhor próxima campanha',
    features:
      'view_count, select_count, recency_days, net_revenue, favorite_category, favorite_brand',
    algorithm:
      'Regressão logística por campanha, treinada em exposições e conversões passadas.',
  },
  {
    title: 'Vitrine inteligente personalizada',
    features: 'interaction_weight (produtos comprados por cliente)',
    algorithm: 'Cosine similarity produto x produto sobre o histórico de compras.',
  },
]

const PLACEHOLDER_IMAGE =
  'data:image/svg+xml;utf8,' +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80"><rect width="80" height="80" fill="#eee"/><text x="40" y="46" font-size="28" text-anchor="middle">🛍️</text></svg>'
  )

async function fetchJSON(url) {
  const res = await fetch(url)
  if (!res.ok) throw new Error(res.status === 404 ? 'Cliente não encontrado' : 'Erro na API')
  return res.json()
}

function Card({ title, children }) {
  return (
    <div className="card">
      <h3>{title}</h3>
      {children}
    </div>
  )
}

export default function App() {
  const [segments, setSegments] = useState([])
  const [customers, setCustomers] = useState([])
  const [query, setQuery] = useState('')
  const [showSuggestions, setShowSuggestions] = useState(false)
  const [result, setResult] = useState(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    fetchJSON(`${API_URL}/segments`).then(setSegments).catch(() => {})
    fetchJSON(`${API_URL}/customers`).then(setCustomers).catch(() => {})
  }, [])

  const q = query.trim().toLowerCase()
  const suggestions = customers.filter(
    (c) => !q || c.customer_id.toLowerCase().includes(q) || (c.full_name ?? '').toLowerCase().includes(q)
  )

  async function runSearch(customerId) {
    if (!customerId.trim()) return
    setShowSuggestions(false)
    setLoading(true)
    setError('')
    setResult(null)
    try {
      const [segment, campaign, showcase] = await Promise.all([
        fetchJSON(`${API_URL}/customers/${customerId}/segment`),
        fetchJSON(`${API_URL}/customers/${customerId}/next-best-campaign`),
        fetchJSON(`${API_URL}/customers/${customerId}/showcase`),
      ])
      setResult({ segment, campaign, showcase })
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  function handleSubmit(e) {
    e.preventDefault()
    const match = customers.find((c) => (c.full_name ?? '').toLowerCase() === q)
    runSearch(match ? match.customer_id : query.trim())
  }

  function selectSuggestion(c) {
    setQuery(c.full_name ?? c.customer_id)
    runSearch(c.customer_id)
  }

  return (
    <div className="app">
      <aside className="left">
        <form onSubmit={handleSubmit} className="search-wrap">
          <div className="search">
            <input
              value={query}
              onChange={(e) => {
                setQuery(e.target.value)
                setShowSuggestions(true)
              }}
              onFocus={() => setShowSuggestions(true)}
              onBlur={() => setTimeout(() => setShowSuggestions(false), 150)}
              placeholder="Buscar cliente por nome ou ID"
            />
            <button type="submit">🔍</button>
          </div>
          {showSuggestions && suggestions.length > 0 && (
            <ul className="suggestions">
              {suggestions.map((c) => (
                <li key={c.customer_id} onMouseDown={() => selectSuggestion(c)}>
                  {c.full_name ?? c.customer_id}
                </li>
              ))}
            </ul>
          )}
        </form>

        {loading && <p>Carregando...</p>}
        {error && <p className="error">{error}</p>}

        {result && (
          <>
            <Card title={result.segment.segment_label ?? 'Sem segmento'}>
              <p>Tier: {result.segment.tier ?? '—'}</p>
            </Card>

            <Card title="Melhor campanha">
              <p>{result.campaign.promotion_name ?? 'Nenhuma campanha sugerida'}</p>
              <p>Motivo: {result.campaign.reason ?? '—'}</p>
              <p>Score: {result.campaign.score?.toFixed(2) ?? '—'}</p>
            </Card>

            <Card title="Vitrine">
              {result.showcase.items.length === 0 && <p>Sem recomendações</p>}
              <div className="showcase-grid">
                {result.showcase.items.map((item) => (
                  <div key={item.rank} className="product-card">
                    <img
                      src={item.image_url || PLACEHOLDER_IMAGE}
                      onError={(e) => {
                        e.currentTarget.src = PLACEHOLDER_IMAGE
                      }}
                      alt={item.product_name ?? item.product_id}
                    />
                    <p className="product-name">{item.product_name ?? item.product_id}</p>
                    {item.price != null && (
                      <p className="product-price">R$ {item.price.toFixed(2)}</p>
                    )}
                    <p className="product-reason">{item.reason}</p>
                  </div>
                ))}
              </div>
            </Card>
          </>
        )}
      </aside>

      <main className="right">
        <div className="segments-grid">
          {Object.keys(SEGMENT_DESCRIPTIONS).map((label) => (
            <Card key={label} title={label}>
              <p>{segments.find((s) => s.segment_label === label)?.customer_count ?? 0} usuários</p>
              <p className="segment-description">{SEGMENT_DESCRIPTIONS[label]}</p>
            </Card>
          ))}
        </div>

        {USE_CASES.map((uc) => (
          <Card key={uc.title} title={uc.title}>
            <p>Features: {uc.features}</p>
            <p>Algoritmo: {uc.algorithm}</p>
          </Card>
        ))}
      </main>
    </div>
  )
}
