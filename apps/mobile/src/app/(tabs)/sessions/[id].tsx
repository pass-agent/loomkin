import React, { useState, useRef, useCallback, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  FlatList,
  Pressable,
  KeyboardAvoidingView,
  Platform,
  Modal,
  type TextInput as TextInputType,
} from "react-native";
import { useLocalSearchParams, Stack } from "expo-router";
import { Ionicons } from "@expo/vector-icons";
import { useQueryClient } from "@tanstack/react-query";
import {
  useSession,
  useSessionMessages,
  useSendMessage,
} from "@/hooks/useSessions";
import { useSessionChannel } from "@/channels/useSessionChannel";
import { ChatBubble } from "@/components/ChatBubble";
import { CostBadge } from "@/components/CostBadge";
import { LoadingSpinner } from "@/components/LoadingSpinner";
import { EmptyState } from "@/components/EmptyState";
import { COLORS, FONT_SIZES, SPACING, QUERY_KEYS } from "@/lib/constants";
import { sessionTitle, formatCost, formatTokens } from "@/lib/formatters";
import type { Message } from "@/lib/types";

export default function SessionDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const queryClient = useQueryClient();
  const flatListRef = useRef<FlatList<Message>>(null);
  const inputRef = useRef<TextInputType>(null);
  const [inputText, setInputText] = useState("");
  const [costModalVisible, setCostModalVisible] = useState(false);

  const { data: session, isLoading: sessionLoading } = useSession(id);
  const {
    data: messages,
    isLoading: messagesLoading,
  } = useSessionMessages(id);
  const sendMessage = useSendMessage(id!);

  // Real-time channel subscription
  const handleNewMessage = useCallback(
    (message: Message) => {
      queryClient.setQueryData<Message[]>(
        QUERY_KEYS.sessionMessages(id!),
        (old) => {
          if (!old) return [message];
          // Avoid duplicates
          if (old.some((m) => m.id === message.id)) return old;
          return [...old, message];
        }
      );
    },
    [id, queryClient]
  );

  const handleMessageUpdate = useCallback(
    (message: Message) => {
      queryClient.setQueryData<Message[]>(
        QUERY_KEYS.sessionMessages(id!),
        (old) => {
          if (!old) return [message];
          return old.map((m) => (m.id === message.id ? message : m));
        }
      );
    },
    [id, queryClient]
  );

  useSessionChannel({
    sessionId: id,
    onNewMessage: handleNewMessage,
    onMessageUpdate: handleMessageUpdate,
    onSessionUpdate: () => {
      queryClient.invalidateQueries({
        queryKey: QUERY_KEYS.session(id!),
      });
    },
  });

  // Scroll to bottom when new messages arrive
  useEffect(() => {
    if (messages && messages.length > 0) {
      // Small delay to allow FlatList to render
      setTimeout(() => {
        flatListRef.current?.scrollToEnd({ animated: true });
      }, 100);
    }
  }, [messages?.length]);

  const handleSend = useCallback(() => {
    const text = inputText.trim();
    if (!text || sendMessage.isPending) return;

    setInputText("");
    sendMessage.mutate(text);
  }, [inputText, sendMessage]);

  const renderMessage = useCallback(
    ({ item }: { item: Message }) => (
      <ChatBubble
        message={item}
        testID={`session-message-${item.id}`}
      />
    ),
    []
  );

  const isLoading = sessionLoading || messagesLoading;

  return (
    <>
      <Stack.Screen
        options={{
          title: session
            ? sessionTitle(session.title, session.id)
            : "Session",
          headerRight: () =>
            session ? (
              <CostBadge
                costUsd={session.cost_usd}
                tokens={session.prompt_tokens + session.completion_tokens}
                onPress={() => setCostModalVisible(true)}
                testID="session-header-cost-badge"
              />
            ) : null,
        }}
      />

      <KeyboardAvoidingView
        style={styles.container}
        behavior={Platform.OS === "ios" ? "padding" : "height"}
        keyboardVerticalOffset={Platform.OS === "ios" ? 90 : 0}
        testID="chat-screen"
      >
        {isLoading ? (
          <LoadingSpinner fullScreen message="Loading conversation..." />
        ) : (
          <>
            {/* Model indicator */}
            {session && (
              <View style={styles.modelBar}>
                <Ionicons
                  name="cube-outline"
                  size={14}
                  color={COLORS.textMuted}
                />
                <Text style={styles.modelText}>{session.model}</Text>
              </View>
            )}

            {/* Messages */}
            <FlatList
              ref={flatListRef}
              data={messages ?? []}
              keyExtractor={(item) => item.id}
              renderItem={renderMessage}
              contentContainerStyle={styles.messagesList}
              ListEmptyComponent={
                <EmptyState
                  icon="chatbubble-ellipses-outline"
                  title="Start the conversation"
                  description="Send a message to begin."
                  testID="session-empty-state"
                />
              }
              onContentSizeChange={() => {
                flatListRef.current?.scrollToEnd({ animated: false });
              }}
            />

            {/* Composer */}
            <View style={styles.composerContainer}>
              <View style={styles.composer}>
                <TextInput
                  ref={inputRef}
                  style={styles.composerInput}
                  placeholder="Type a message..."
                  placeholderTextColor={COLORS.textMuted}
                  value={inputText}
                  onChangeText={setInputText}
                  multiline
                  maxLength={10000}
                  returnKeyType="default"
                  testID="session-message-input"
                />
                <Pressable
                  style={[
                    styles.sendButton,
                    (!inputText.trim() || sendMessage.isPending) &&
                      styles.sendButtonDisabled,
                  ]}
                  onPress={handleSend}
                  disabled={!inputText.trim() || sendMessage.isPending}
                  testID="session-send-button"
                >
                  {sendMessage.isPending ? (
                    <LoadingSpinner size="small" />
                  ) : (
                    <Ionicons
                      name="send"
                      size={20}
                      color={COLORS.white}
                    />
                  )}
                </Pressable>
              </View>
            </View>
          </>
        )}
      </KeyboardAvoidingView>

      {/* Cost Detail Modal */}
      <Modal
        visible={costModalVisible}
        transparent
        animationType="fade"
        onRequestClose={() => setCostModalVisible(false)}
      >
        <Pressable
          style={styles.modalOverlay}
          onPress={() => setCostModalVisible(false)}
        >
          <View
            style={styles.modalContent}
            testID="cost-detail-modal"
            onStartShouldSetResponder={() => true}
          >
            <Text style={styles.modalTitle} testID="cost-detail-modal-title">Cost Breakdown</Text>

            {session && (
              <View style={styles.modalBody}>
                <View style={styles.costRow}>
                  <Text style={styles.costLabel}>Model</Text>
                  <Text style={styles.costValue}>{session.model}</Text>
                </View>
                <View style={styles.costRow}>
                  <Text style={styles.costLabel}>Total Cost</Text>
                  <Text style={styles.costValueHighlight}>
                    {formatCost(session.cost_usd)}
                  </Text>
                </View>
                <View style={styles.costRow}>
                  <Text style={styles.costLabel}>Prompt Tokens</Text>
                  <Text style={styles.costValue}>
                    {formatTokens(session.prompt_tokens)}
                  </Text>
                </View>
                <View style={styles.costRow}>
                  <Text style={styles.costLabel}>Completion Tokens</Text>
                  <Text style={styles.costValue}>
                    {formatTokens(session.completion_tokens)}
                  </Text>
                </View>
                <View style={styles.costRow}>
                  <Text style={styles.costLabel}>Total Tokens</Text>
                  <Text style={styles.costValue}>
                    {formatTokens(
                      session.prompt_tokens + session.completion_tokens
                    )}
                  </Text>
                </View>
              </View>
            )}

            <Pressable
              style={styles.modalCloseButton}
              onPress={() => setCostModalVisible(false)}
              testID="cost-detail-modal-close-button"
            >
              <Text style={styles.modalCloseText}>Close</Text>
            </Pressable>
          </View>
        </Pressable>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: COLORS.background,
  },
  modelBar: {
    flexDirection: "row",
    alignItems: "center",
    gap: SPACING.xs,
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.sm,
    backgroundColor: COLORS.surface,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  modelText: {
    fontSize: FONT_SIZES.xs,
    color: COLORS.textMuted,
    fontFamily: "monospace",
  },
  messagesList: {
    paddingVertical: SPACING.md,
    flexGrow: 1,
  },
  composerContainer: {
    backgroundColor: COLORS.surface,
    borderTopWidth: 1,
    borderTopColor: COLORS.border,
    paddingHorizontal: SPACING.md,
    paddingVertical: SPACING.md,
    paddingBottom: Platform.OS === "ios" ? SPACING.xl : SPACING.md,
  },
  composer: {
    flexDirection: "row",
    alignItems: "flex-end",
    gap: SPACING.sm,
  },
  composerInput: {
    flex: 1,
    backgroundColor: COLORS.surfaceLight,
    borderRadius: 20,
    paddingHorizontal: SPACING.lg,
    paddingVertical: SPACING.md,
    fontSize: FONT_SIZES.base,
    color: COLORS.text,
    maxHeight: 120,
    borderWidth: 1,
    borderColor: COLORS.border,
  },
  sendButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: COLORS.primary,
    alignItems: "center",
    justifyContent: "center",
  },
  sendButtonDisabled: {
    opacity: 0.4,
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0, 0, 0, 0.6)",
    justifyContent: "center",
    alignItems: "center",
    padding: SPACING.xl,
  },
  modalContent: {
    backgroundColor: COLORS.surface,
    borderRadius: 16,
    padding: SPACING.xl,
    width: "100%",
    maxWidth: 360,
    gap: SPACING.lg,
  },
  modalTitle: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.text,
    textAlign: "center",
  },
  modalBody: {
    gap: SPACING.md,
  },
  costRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingVertical: SPACING.sm,
    borderBottomWidth: 1,
    borderBottomColor: COLORS.border,
  },
  costLabel: {
    fontSize: FONT_SIZES.base,
    color: COLORS.textSecondary,
  },
  costValue: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
    fontFamily: "monospace",
  },
  costValueHighlight: {
    fontSize: FONT_SIZES.lg,
    fontWeight: "700",
    color: COLORS.warning,
  },
  modalCloseButton: {
    backgroundColor: COLORS.surfaceLight,
    height: 44,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
  },
  modalCloseText: {
    fontSize: FONT_SIZES.base,
    fontWeight: "600",
    color: COLORS.text,
  },
});
