import React, { useEffect, useState } from "react";
import { Text } from "ink";

interface Props {
  toolUseId: string;
  getCount: (id: string) => number;
}

export function HookProgressDisplay({ toolUseId, getCount }: Props) {
  const count = getCount(toolUseId);
  const [justCompleted, setJustCompleted] = useState(false);

  useEffect(() => {
    if (count > 0) {
      setJustCompleted(true);
    } else if (justCompleted) {
      const t = setTimeout(() => setJustCompleted(false), 1500);
      return () => clearTimeout(t);
    }
  }, [count]);

  if (count > 0) return <Text dimColor> ↳ running hook...</Text>;
  if (justCompleted)
    return (
      <Text color="green" dimColor>
        {" "}
        ↳ ✓ hook complete
      </Text>
    );
  return null;
}
