import { useState } from 'react'

export default function App() {
  const [count, setCount] = useState(0)

  return (
    <main>
      <h1>Counter App</h1>
      <output aria-label="Counter" aria-live="polite">{count}</output>
      <div className="actions">
        <button onClick={() => setCount((value) => value + 1)}>Increment</button>
        <button className="secondary" onClick={() => setCount(0)}>Reset</button>
      </div>
    </main>
  )
}
