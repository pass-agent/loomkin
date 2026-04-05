import React from 'react'
import { Box, Text } from 'ink'
import type { GroupedToolUse } from '../lib/types.js'

interface Props {
  toolUses: GroupedToolUse[]
}

export function GroupedToolDisplay({ toolUses }: Props) {
  const inProgress = toolUses.filter(t => t.isInProgress).length
  const errors = toolUses.filter(t => t.isError).length
  const allDone = inProgress === 0

  return (
    <Box flexDirection="column">
      {allDone ? (
        <Text color={errors > 0 ? 'yellow' : 'green'}>
          {errors > 0 ? '⚠' : '✓'} {toolUses.length} tools complete{errors > 0 ? ` (${errors} failed)` : ''}
        </Text>
      ) : (
        <Text>⟳ Running {toolUses.length} tools in parallel...</Text>
      )}
      {toolUses.map(t => (
        <Box key={t.toolUseId} marginLeft={2}>
          <Text dimColor>• {t.toolName}</Text>
        </Box>
      ))}
    </Box>
  )
}
