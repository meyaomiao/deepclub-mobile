import { HarnessError } from '@deepseek-ai/dsh-llm';

const messages = {
  authorization: '当前设备未授权此工具、模型、端点或规格。请刷新深云账号配置。',
  credential: '深云登录已失效，请重新登录。',
  request: '参数不符合当前授权规格，请使用工具列出的模型和规格。',
  approval: '本次付费操作未获批准，没有提交生成请求。',
  permission: '当前会话无权访问此文件、工作区或任务。',
  filesystem: '文件服务拒绝操作或工作区发生变化；请检查工作区权限后重试。',
  reference: '参考图必须是用户在当前请求中指定的工作区 PNG、JPEG 或 WebP 文件。',
  network: '深云请求连接失败；若已提交，服务端可能继续并收费。请勿自动重新提交。',
  response: '深云返回了无效或过大的结果；请勿自动重新提交付费请求。',
  http: '深云请求失败；请检查账号余额、模型可用性与网络。请勿自动重新提交。',
  task_failed: '视频服务返回失败状态；实际收费以服务账单为准。',
  cancelled: '本地操作或等待已停止；已提交的服务端任务可能继续并收费，未确认上游取消或退款。',
  timeout: '等待深云结果超时；服务端任务可能继续并收费，请勿重新提交。',
  unsafe_url: '服务地址或结果下载地址不在允许范围。',
};
export class ToolError extends HarnessError {
  constructor(kind) { super(messages[kind], 'DEEPCLUB_TOOLS_' + kind.toUpperCase()); this.kind = kind; }
}
export function fail(kind) { throw new ToolError(kind); }
export function check(signal) { if (signal?.aborted) fail('cancelled'); }
export function safeError(error, signal) {
  if (error instanceof ToolError) return error;
  if (signal?.aborted) return new ToolError('cancelled');
  if (typeof error?.code === 'string' && (error.code.startsWith('FS_')
    || ['ENOENT', 'EACCES', 'EPERM', 'ENOTDIR', 'EISDIR', 'ENOSPC', 'ELOOP', 'EDQUOT'].includes(error.code))) return new ToolError('filesystem');
  return new ToolError('network');
}
